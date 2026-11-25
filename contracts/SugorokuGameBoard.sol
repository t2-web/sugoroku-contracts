// SPDX-License-Identifier: MIT
// ABOUTME: Implements per-game board mechanics, player balances, and leaderboard rewards.
// ABOUTME: Keeps persistent PlayerProgressSBT metrics synchronized with canonical game state.
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { TransientSlot } from "@openzeppelin/contracts/utils/TransientSlot.sol";
// Named import: LeaderboardLib.sol also declares its own metrics interface, and
// pulling that in would collide with IPlayerProgressSBT declared below.
import { LeaderboardLib } from "./libraries/LeaderboardLib.sol";
import { GoalRewardLib, IGoalNftPrizes } from "./libraries/GoalRewardLib.sol";

/**
 * @title IPlayerProgressSBT
 * @dev Interface for querying player metrics from PlayerProgressSBT
 */
interface IPlayerProgressSBT {
    function getPlayerMetrics(
        address player,
        uint256 gameId
    ) external view returns (uint256 ownedSgp, uint256 earnedSgp, uint256 dicePurchased);

    function batchUpdatePlayer(
        address player,
        uint256 gameId,
        int256 ownedDelta,
        uint256 earnedAdd,
        uint256 diceAdd
    ) external;

    function batchGetPlayerMetrics(
        address[] calldata players,
        uint256[] calldata gameIds
    )
        external
        view
        returns (
            uint256[] memory ownedSgp,
            uint256[] memory earnedSgp,
            uint256[] memory dicePurchased
        );
}

/**
 * @title ISugorokuAMMPool
 * @dev Interface for AMM pool swap operations
 */
interface ISugorokuAMMPool {
    /**
     * @notice Swap tokens via AMM pool
     * @param amountIn Amount of input token to swap
     * @param minAmountOut Minimum output to receive (slippage protection)
     * @param tokenIn Address of input token (USDC or SGP)
     * @param to Address to receive output tokens
     * @return amountOut Actual amount received
     */
    function swap(
        uint256 amountIn,
        uint256 minAmountOut,
        address tokenIn,
        address to
    ) external returns (uint256 amountOut);

    /**
     * @notice Calculate output amount for a given input amount
     * @param amountIn Amount of input token
     * @param tokenIn Address of input token
     * @return amountOut Amount of output token
     * @return feeAmount Fee amount deducted from input
     */
    function getAmountOut(
        uint256 amountIn,
        address tokenIn
    ) external view returns (uint256 amountOut, uint256 feeAmount);

    /**
     * @notice Get payment token (token0 = USDC)
     * @return Address of token0
     */
    function token0() external view returns (IERC20);

    /**
     * @notice Get game token (token1 = SGP)
     * @return Address of token1
     */
    function token1() external view returns (IERC20);
}

/**
 * @title SugorokuGameBoard
 * @dev Upgradable core game mechanics and logic contract deployed by SugorokuGameRegistry
 * @notice Handles individual game instances with board logic, player movement, and lottery mechanics
 * @author Sugoroku Team
 *
 * This contract is deployed by the SugorokuGameRegistry factory and contains:
 * - Individual game state management
 * - Player movement and dice rolling logic
 * - Lottery and jackpot processing
 * - Integration PlayerProgressSBT
 * - Beacon Proxy upgradeability for centralized upgrade management
 *
 * Upgradeability Features:
 * - Beacon Proxy pattern for centralized upgrades via UpgradeableBeacon
 * - Registry controls the Beacon, which manages implementation upgrades
 * - Version tracking for compatibility
 * - State preservation across upgrades
 * - Storage gap reserved for future state variables
 */
contract SugorokuGameBoard is Initializable, AccessControlUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;
    using TransientSlot for *;
    // ========================================================================
    // ROLE DEFINITIONS
    // ========================================================================

    /// @notice Role identifier for game engine operations
    bytes32 public constant GAME_ENGINE_ROLE = keccak256("GAME_ENGINE_ROLE");

    /// @notice Role identifier for external dice redeemer contracts
    bytes32 public constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");
    /// @dev May settle other players' moves and force their exits (the auto-claim keeper); a
    ///      player does both for themself.
    ///      Private to save bytecode: the role id is keccak256("FINALIZER_ROLE").
    bytes32 private constant FINALIZER_ROLE = keccak256("FINALIZER_ROLE");

    // ========================================================================
    // GAME CONSTANTS
    // ========================================================================

    /// @notice Contract version for upgrade compatibility
    uint256 public constant CONTRACT_VERSION = 13;

    /// @notice BSC BEP-440 history contract for block hashes older than 256 blocks
    address private constant BLOCK_HASH_HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;

    /// @dev Bit 255 of freeDiceCount: the pending move was requested with a free die (V12)
    uint256 private constant FREE_MOVE_PENDING = 1 << 255;

    /// @dev Storage slots that LeaderboardLib writes by DELEGATECALL for the cold admin
    ///      paths moved out of this contract. Beacon upgrades fix every slot for good, and
    ///      test/GoalPayoutStorage.test.ts checks each constant against the compiler layout.
    uint256 private constant PLATFORM_FEE_SLOT = 26;
    uint256 private constant LEADERBOARD_BUDGET_SLOT = 27;
    uint256 private constant TREASURY_SLOT = 28;
    uint256 private constant DICE_PRICE_SLOT = 29;
    uint256 private constant REWARD_CLAIM_PERIOD_SLOT = 40;
    uint256 private constant OPERATOR_TOKEN_SLOT = 42;
    uint256 private constant GOAL_TREASURY_USDC_SLOT = 45;
    uint256 private constant GOAL_FEE_RATE_SLOT = 46;

    /// @dev Transient-storage slot of the exit lock. Transient storage is separate from
    ///      the persistent layout, and LeaderboardLib's lock uses a hashed slot.
    bytes32 private constant EXIT_LOCK = bytes32(uint256(1));

    /// @dev Domain separators prevent the dice and tile effects from reusing one random value
    uint256 private constant LOTTERY_RANDOM_DOMAIN = 2;
    uint256 private constant JACKPOT_RANDOM_DOMAIN = 3;
    uint256 private constant GOAL_RANDOM_DOMAIN = 4;

    /// @dev Share of every lottery loss accrued to the operator in game tokens (1000 = 10%)
    uint256 private constant OPERATOR_TOKEN_SHARE_BPS = 1000;

    /// @notice Basis points denominator (10000 = 100%)
    uint256 private constant BASIS_POINTS = 10000;

    /// @notice Default dice price in USDC (10 USDC with 6 decimals)
    uint256 private constant DEFAULT_DICE_PRICE_USDC = 10_000_000;

    /// @notice Default platform fee rate (5% = 500 basis points)
    uint256 private constant DEFAULT_PLATFORM_FEE_RATE = 500;

    /// @notice Default leaderboard fee rate (25% = 2500 basis points)
    uint256 private constant DEFAULT_LEADERBOARD_FEE_RATE = 2500;

    /// @notice Default AMM pool fee rate (70% = 7000 basis points)
    uint256 private constant DEFAULT_AMM_POOL_FEE_RATE = 7000;

    /// @notice Maximum number of players allowed per game instance
    uint256 public constant MAX_PLAYERS = 1000;

    /// @notice Grace period before the keeper can force-claim for a player (5 minutes)
    uint256 private constant CLAIM_GRACE_PERIOD = 5 minutes;

    /// @notice Maximum number of reward tiers for leaderboard distribution
    uint256 private constant MAX_REWARD_TIERS = 10;

    /// @notice Default claim deadline for leaderboard rewards (30 days)
    uint256 private constant DEFAULT_REWARD_CLAIM_PERIOD = 30 days;

    // ========================================================================
    // CORE STRUCTS
    // ========================================================================

    /**
     * @notice Player information structure
     * @dev Optimized for gas efficiency with packed storage
     */
    struct Player {
        address playerAddress; // Player's wallet address
        uint256 position; // Current position on board (0-indexed)
        uint256 sgpBalance; // SGP balance in this game
        uint256 goalUsdcPending; // Goal bonus in USDC, credited on goal and paid on exit
        uint256 gameSGPBalance; // Player's total SGP balance in the game (from dice purchases + lottery wins/losses)
        uint256 lastMoveTime; // Timestamp of last move
        bool active; // Player active status
        bool roundCompleted; // True after forward movement completes a round at position 0
        uint256 totalMoves; // Total number of moves made
        uint256 diceCount; // Total dice purchased (for PlayerProgressSBT tracking)
        uint256 totalSgpEarned; // Total SGP earned (for leaderboard)
        uint256 totalSgpLost; // Total SGP lost in lotteries
        uint256 claimDeadline; // Timestamp after which a FINALIZER_ROLE holder can force-claim for this player
    }

    /**
     * @notice Lightweight player data for batch reads
     * @dev Only includes fields needed by the frontend for rendering and display.
     *      Excludes sgpBalance, goalUsdcPending, totalMoves, totalSgpLost, claimDeadline.
     */
    struct PlayerView {
        address playerAddress;
        uint256 position;
        uint256 gameSGPBalance;
        uint256 diceCount;
        bool active;
        bool roundCompleted;
        uint256 totalSgpEarned;
        uint256 lastMoveTime;
    }

    /**
     * @notice Game configuration stored at creation time (immutable after deployment)
     * @dev Critical configuration that cannot be changed after initialization
     */
    struct GameConfig {
        uint256 gameId; // Unique game identifier from registry
        uint256 boardType; // Board size (30, 50, or 100)
        uint256 templateVersion; // Template version used
        bytes32 boardSeed; // Seed for deterministic board generation
        address registry; // Registry that deployed this contract
        uint256 creationTime; // Contract deployment time
        bool gameActive; // Game active status
        uint256 contractVersion; // Version of deployed contract
    }

    // ========================================================================
    // TILE TYPES AND CONFIGURATION
    // ========================================================================

    /**
     * @notice Types of tiles on the game board
     * @dev Must match backend TileType enum exactly for 1:1 compatibility
     */
    enum TileType {
        START_GOAL, // 0 - Entry/exit point (position 0)
        BLANK, // 1 - No effect
        MOVE_FORWARD, // 2 - Advance by effect value
        MOVE_BACKWARD, // 3 - Retreat by effect value
        LOTTERY_1, // 4 - Bronze lottery (80% win rate)
        LOTTERY_2, // 5 - Silver lottery (50% win rate)
        LOTTERY_3, // 6 - Gold lottery (10% win rate)
        JACKPOT, // 7 - Grand prize lottery (5% win rate)
        CHALLENGE // 8 - Reserved for future use
    }

    /**
     * @notice Configuration for a single tile on the board
     * @dev Packed for gas efficiency
     */
    struct TileConfig {
        TileType tileType; // Type of tile
        int16 effectValue; // Effect magnitude (positive=forward, negative=backward)
    }

    /**
     * @notice Lottery configuration for each lottery tier
     * @dev Rates are in basis points (100 = 1%)
     */
    struct LotteryConfig {
        uint16 winRate; // Win probability (e.g., 8000 = 80%)
        uint16 poolPayoutRate; // Percentage of pool to pay on win (e.g., 2000 = 20%)
        uint16 lossStakeRate; // Percentage of stake lost on loss (e.g., 2000 = 20%)
    }

    // RewardTier, DistributionRecord and ClaimRecord moved verbatim into
    // LeaderboardLib, so the library can take playerClaimRecords as a storage
    // pointer. Field order and widths are unchanged, so the slot layout is too.

    // ========================================================================
    // STATE VARIABLES
    // ========================================================================

    /// @notice Game configuration (set once at initialization)
    GameConfig public gameConfig;

    /// @notice Mapping from player address to player data
    mapping(address => Player) public players;

    /// @notice Array of active player addresses for iteration
    address[] public playerAddresses;

    /// @notice Mapping from player address to index in playerAddresses array
    /// @dev Used for O(1) removal via swap-and-pop pattern
    mapping(address => uint256) private playerIndexInArray;

    /// @notice Total SGP pool in the game
    uint256 public totalSgpPool;

    /// @notice Total USDC pool in the game
    uint256 public totalUsdcPool;

    address public playerProgressSBT;

    /// @notice USDC token contract for dice purchases
    IERC20 public usdcToken;

    /// @notice AMM pool for USDC ⇄ SGP swaps
    ISugorokuAMMPool public ammPool;

    /// @notice SGP token contract (game token)
    IERC20 public sgpToken;

    /// @notice Total number of players in the game
    uint256 public playerCount;

    /// @notice Total dice rolls in this game (for randomness)
    uint256 public totalDiceRolls;

    // ========================================================================
    // TILE AND LOTTERY STORAGE
    // ========================================================================

    /// @notice Board tile configurations (position => TileConfig)
    mapping(uint256 => TileConfig) public tiles;

    /// @notice Lottery configurations for each tier
    /// @dev Index: 0=Bronze(LOTTERY_1), 1=Silver(LOTTERY_2), 2=Gold(LOTTERY_3), 3=Jackpot
    LotteryConfig[4] public lotteryConfigs;

    /// @notice Lottery pools per tile position (each lottery tile has its own pool)
    /// @dev Key: tile position, Value: pool SGP balance
    mapping(uint256 => uint256) public lotteryPools;

    /// @notice Array of lottery tile positions (for iteration when calculating jackpot)
    uint256[] public lotteryTilePositions;

    /// @notice Maximum chained effect iterations to prevent infinite loops
    uint256 private constant MAX_CHAIN_ITERATIONS = 10;

    // ========================================================================
    // FEE TRACKING STORAGE (V2)
    // ========================================================================

    /// @notice Accumulated platform fees in USDC
    uint256 public platformFeeAccumulated;

    /// @notice Accumulated leaderboard fees in USDC
    uint256 public leaderboardFeeAccumulated;

    /// @notice Treasury address for platform fee withdrawals
    address public treasury;

    // ========================================================================
    // CONFIGURABLE FEE PARAMETERS (V2)
    // ========================================================================

    /// @notice Dice price in USDC (configurable, 6 decimals)
    uint256 public dicePrice;

    /// @notice Platform fee rate (basis points, e.g., 500 = 5%)
    uint256 public platformFeeRate;

    /// @notice Leaderboard rewards fee rate (basis points, e.g., 2500 = 25%)
    uint256 public leaderboardFeeRate;

    /// @notice AMM pool fee rate (basis points, e.g., 7000 = 70%)
    uint256 public ammPoolFeeRate;

    // ========================================================================
    // LEADERBOARD REWARD DISTRIBUTION STORAGE (V3)
    // ========================================================================

    /// @notice Reward tier percentages for top players (basis points, sum = 10000)
    LeaderboardLib.RewardTier[] public rewardTiers;

    /// @notice Individual claim records per player address
    mapping(address => LeaderboardLib.ClaimRecord[]) public playerClaimRecords;

    /// @notice Distribution history records
    LeaderboardLib.DistributionRecord[] public distributionHistory;

    /// @notice Total USDC distributed to leaderboard players across all distributions
    uint256 public totalLeaderboardDistributed;

    /// @notice Total number of distributions that have occurred
    uint256 public distributionCount;

    /// @notice Total unclaimed rewards currently pending
    uint256 public totalUnclaimedRewards;

    /// @notice Claim deadline for current distribution round
    uint256 public rewardClaimDeadline;

    /// @notice Configurable claim period in seconds (default: 30 days)
    uint256 public rewardClaimPeriod;

    // ========================================================================
    // ASYNC MOVE STORAGE (V4)
    // ========================================================================

    /// @notice Move requests waiting for their fixed future block and settlement
    mapping(address => uint256) public pendingMoveTargetBlocks;

    // ========================================================================
    // OPERATOR TOKEN ACCRUAL (V5 slot, renamed in V9)
    // ========================================================================

    /// @notice Game tokens owed to the operator: OPERATOR_TOKEN_SHARE_BPS of lottery losses.
    /// @dev Was the V5-V8 SGP goal treasury. Keeping the slot turns that balance into
    ///      operator accrual at upgrade. Sent to `treasury` by withdrawPlatformFees,
    ///      which leaves 1 wei behind once the slot is nonzero.
    /// @custom:oz-renamed-from goalTreasury
    uint256 public operatorTokenAccrued;

    // ========================================================================
    // PACKED LEADERBOARD METRICS (V6)
    // ========================================================================

    /// @dev V6-V11 jackpot ranking mirror (Owned, Earned, Dice per player). No longer
    ///      written or read since V12, which ranks per season; kept so later slots stay put.
    mapping(address => uint256) private packedMetrics;

    // V7 consumes one reserved slot. Zero storage on upgraded boards means 1-50.
    uint8 private goalPayoutMinPct;
    uint8 private goalPayoutMaxPct;

    // ========================================================================
    // USDC GOAL TREASURY (V9)
    // ========================================================================

    /// @notice USDC reserved for goal bonuses (6 decimals); a goal moves 1-50% to the player
    uint256 public goalTreasuryUsdc;

    /// @notice Goal treasury share of each dice purchase (basis points). Zero after upgrade.
    uint256 public goalFeeRate;

    // ========================================================================
    // SEASON RANKING (V12)
    // ========================================================================
    // A season is one UTC calendar month, id `year * 12 + (month - 1)`. LeaderboardLib
    // reads and writes the first four by fixed slot (47..50), so they can never move.

    /// @notice Season values per player: bits 0..95 Earned (tokens won by rolls of paid
    ///         dice), bits 96..127 Dice (dice bought with USDC)
    mapping(uint256 => mapping(address => uint256)) public seasonStats;

    /// @dev Players with a value in each season, in the order they first scored
    mapping(uint256 => address[]) private seasonPlayers;

    /// @notice Leaderboard USDC added during each season (purchase shares and admin funding)
    mapping(uint256 => uint256) public seasonPool;

    /// @notice Oldest season not yet settled; 0 until a player first scores on V12
    uint256 public nextSeasonToSettle;

    /// @notice Granted dice (grantDice) a player has not rolled yet, in the low bits. requestMove
    ///         spends them before paid dice, and their rolls count in no season and no SBT metric.
    ///         Bit 255 is set while the pending move was requested with one of them, so the
    ///         getter then returns 2^255 + n; readers mask it with `& (2^255 - 1)` for the count.
    /// @dev Kept out of the Player struct so getPlayer / players keep their V11 ABI.
    mapping(address => uint256) public freeDiceCount;

    // ========================================================================
    // GOAL ODDS (V13)
    // ========================================================================

    /// @dev The goal odds table and the GoalNftPrizes contract, packed as 64 uint16 entries
    ///      (16 per slot): entry 0 is 1 while a table is set, entries 1..51 are running totals
    ///      in 0.01% (entry e < 51 is the chance of 1%..e% of the USDC goal treasury together,
    ///      entry 51 adds the NFT and is 10000), and bits 64..223 of the last slot hold the
    ///      prize contract. GoalRewardLib reads and writes them by slot number (52..55), so
    ///      they can never move.
    uint256[4] private goalOdds;

    // ========================================================================
    // STORAGE GAP
    // ========================================================================

    /// @notice Reserved storage space for future upgrades
    /// @dev This gap allows adding new state variables without breaking storage layout
    /// @dev Reduced from 34 to 25 for V3 leaderboard state and the V4 pendingMoves mapping,
    ///      to 24 for the V5 goalTreasury slot, to 23 for the V6 packed metrics mirror,
    ///      to 22 for the V7 payout range, to 20 for the V9 USDC goal treasury, to
    ///      15 for the V12 season ranking and free dice, then to 11 for the V13 goal odds
    uint256[11] private __gap;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /**
     * @notice Emitted when a player joins the game
     */
    event PlayerJoined(
        address indexed player,
        uint256 position,
        uint256 sgpAmount,
        uint256 timestamp
    );

    /**
     * @notice Emitted when a player buys dice
     */
    event DicePurchased(
        address indexed player,
        uint256 diceAmount,
        uint256 sgpReceived,
        uint256 commissionPaid,
        uint256 timestamp
    );

    /**
     * @notice Emitted when dice are granted by an external redeemer (e.g., DiceNFT burn)
     */
    event DiceGranted(address indexed player, uint256 diceAmount, uint256 timestamp);

    /**
     * @notice Emitted when a player moves
     */
    event PlayerMoved(
        address indexed player,
        uint256 newPosition,
        uint256 diceRoll,
        uint256 sgpEarned,
        uint256 usdcEarned,
        uint256 timestamp
    );

    /**
     * @notice Emitted after a dice is irreversibly consumed for a future-block move
     */
    event MoveRequested(address indexed player, uint256 targetBlock);
    /// @notice Emitted when a move whose target block hash aged out is released; its dice is forfeited
    event StrandedMoveReset(address indexed player, uint256 targetBlock);

    /**
     * @notice Emitted when game status changes
     */
    event GameStatusChanged(
        uint256 indexed gameId,
        bool oldStatus,
        bool newStatus,
        address changedBy
    );

    /**
     * @notice Emitted when a tile effect is processed
     */
    event TileEffectProcessed(
        address indexed player,
        uint256 position,
        TileType tileType,
        int256 effectValue,
        uint256 timestamp
    );

    /**
     * @notice Emitted when a lottery is played
     */
    event LotteryPlayed(
        address indexed player,
        TileType lotteryTier,
        bool won,
        uint256 stakeAmount,
        uint256 payoutAmount,
        uint256 poolAfter
    );

    /**
     * @notice Emitted when forward movement completes a round at position 0
     */
    event RoundCompleted(address indexed player, uint256 roundNumber, uint256 totalSgpEarned);

    /**
     * @notice Emitted once per entry when a player completes a round (also when amount is 0)
     * @param pct Random share of the USDC goal treasury awarded (%): within the payout range,
     *        or drawn from the goal odds (V13), where 0 means the player won an NFT instead
     * @param usdcAmount USDC held for the player and paid when they exit
     */
    event GoalBonusAwarded(address indexed player, uint8 pct, uint256 usdcAmount);
    /// @notice Emitted when an exit pays the player's pending goal bonus in USDC
    event GoalBonusPaid(address indexed player, uint256 amount);
    /// @dev V7-V12 only: V13 dropped setGoalPayoutRange for bytecode (the odds table replaces it).
    ///      Kept so earlier logs still decode against this ABI.
    event GoalPayoutRangeChanged(uint8 minPct, uint8 maxPct);
    /// @notice Emitted when a board without goal odds draws within its payout range
    event GoalPayoutRangeUsed(address indexed player, uint8 minPct, uint8 maxPct);
    /// @notice Emitted (V13, by GoalRewardLib) when a goal wins an NFT; GoalBonusAwarded then has pct 0.
    ///         The NFT is reserved in the goal prize contract and sent when the player exits.
    event GoalNftAwarded(address indexed player, address indexed token, uint256 tokenId);
    /// @notice Emitted (V13, by GoalRewardLib) when the goal odds table or prize contract changes
    event GoalOddsChanged(uint256[4] odds, address prize);

    error InvalidGoalOdds();

    /// @notice Effective inclusive percentage range of a board without goal odds, including
    ///         the legacy upgrade default. V13 can no longer change it; set goal odds instead.
    function getGoalPayoutRange() public view returns (uint8 minPct, uint8 maxPct) {
        maxPct = goalPayoutMaxPct;
        if (maxPct == 0) return (1, 50);
        minPct = goalPayoutMinPct;
    }

    /**
     * @notice Sets the goal odds (V13): 64 uint16 entries packed 16 per word, in 0.01% units.
     *         Entry e in 1..50 is the chance of e% of the USDC goal treasury, entry 51 the
     *         chance of an NFT from `prize`; they sum to 10000, and entries 0 and 52..63 are 0.
     *         All-zero odds return the board to the uniform payout range.
     * @dev No getter, for bytecode: read the four goalOdds slots (52..55), which hold the
     *      running totals, the set flag and the prize contract, or the latest GoalOddsChanged
     *      log, which has the weights as given here.
     */
    function setGoalOdds(
        uint256[4] calldata odds,
        address prize
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        GoalRewardLib.setGoalOdds(odds, prize);
    }

    /**
     * @notice Emitted when a chained effect causes additional movement
     */
    event ChainedMovement(
        address indexed player,
        uint256 fromPosition,
        uint256 toPosition,
        uint256 chainIteration
    );

    /**
     * @notice Emitted when jackpot is won
     */
    event JackpotWon(address indexed winner, uint256 amount, uint256 reseedAmount);

    /**
     * @notice Emitted when lottery pools are reseeded after jackpot
     */
    event PoolsReseeded(uint256 totalReseed, uint256 perPoolAmount);

    /**
     * @notice Emitted when a player exits the game and cashes out
     * @param player Address of the player exiting
     * @param sgpConverted Amount of SGP converted to USDC
     * @param usdcReceived Amount of USDC received by player
     * @param totalSgpEarned Total SGP earned during the game (for leaderboard)
     * @param exitReason Reason for exit (round_completion, jackpot_winner, etc.)
     */
    event GameExited(
        address indexed player,
        uint256 sgpConverted,
        uint256 usdcReceived,
        uint256 totalSgpEarned,
        string exitReason
    );

    /**
     * @notice Emitted when platform fees are withdrawn
     * @param recipient Address receiving the fees
     * @param amount Amount of USDC withdrawn
     */
    event PlatformFeesWithdrawn(address indexed recipient, uint256 amount);

    /// @notice Emitted when the operator's accrued game tokens are sent to the treasury
    event OperatorTokensWithdrawn(address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when leaderboard fees are withdrawn
     * @param recipient Address receiving the fees
     * @param amount Amount of USDC withdrawn
     */
    event LeaderboardFeesWithdrawn(address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when leaderboard rewards are distributed (claimable by players)
     * @param distributionId Sequential distribution identifier
     * @param totalAmount Total USDC made claimable
     * @param jackpotWinner Player who won jackpot and triggered distribution
     * @param winners Array of top player addresses receiving rewards
     * @param amounts Array of USDC amounts per winner
     * @param claimDeadline Timestamp after which unclaimed rewards can be recycled
     */
    event LeaderboardRewardsDistributed(
        uint256 indexed distributionId,
        uint256 totalAmount,
        address indexed jackpotWinner,
        address[] winners,
        uint256[] amounts,
        uint256 claimDeadline
    );

    /**
     * @notice Emitted when a player claims their leaderboard reward
     * @param player Player who claimed
     * @param amount USDC amount claimed
     */
    event LeaderboardRewardClaimed(address indexed player, uint256 amount);

    /**
     * @notice Emitted after expired rewards are transferred to the configured treasury
     * @param admin Authorized caller, which may differ from the recipient
     * @param recipient Configured platform treasury
     * @param amount Total USDC recovered
     * @param recordCount Number of expired claim records consumed
     */
    event ExpiredRewardsClaimed(
        address indexed admin,
        address indexed recipient,
        uint256 amount,
        uint256 recordCount
    );

    /**
     * @notice Emitted when a season is closed (V12; LeaderboardLib emits it)
     * @param season Season id, `year * 12 + (month - 1)`
     * @param distributionId Distribution holding the claim records, or 0 if nothing was paid
     * @param pool Leaderboard USDC the season was settled with
     * @param distributed USDC written into claim records; the rest goes to the next season
     * @param claimDeadline Last second the records can be claimed (end of the next month)
     */
    event SeasonSettled(
        uint256 indexed season,
        uint256 indexed distributionId,
        uint256 pool,
        uint256 distributed,
        uint256 claimDeadline
    );

    /**
     * @notice Emitted when a long season roster was partly ranked (V12; LeaderboardLib emits it)
     * @dev Call settleSeason again until SeasonSettled is emitted
     * @param season Season being settled
     * @param processed Players ranked so far
     * @param total Players in the season
     */
    event SeasonSettlementProgress(uint256 indexed season, uint256 processed, uint256 total);

    /**
     * @notice Emitted when reward tier configuration is updated
     * @param tierCount Number of reward tiers
     */
    event RewardTiersUpdated(uint256 tierCount);

    /**
     * @notice Emitted when reward claim period is updated
     * @param oldPeriod Previous claim period in seconds
     * @param newPeriod New claim period in seconds
     */
    event RewardClaimPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);

    /**
     * @notice Emitted when treasury address is updated
     * @param oldTreasury Previous treasury address
     * @param newTreasury New treasury address
     */
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /**
     * @notice Emitted when fee configuration is updated
     * @param dicePrice New dice price in USDC
     * @param platformFeeRate New platform fee rate
     * @param leaderboardFeeRate New leaderboard fee rate
     * @param ammPoolFeeRate New AMM pool fee rate
     * @param goalFeeRate New goal treasury fee rate
     */
    event FeeConfigUpdated(
        uint256 dicePrice,
        uint256 platformFeeRate,
        uint256 leaderboardFeeRate,
        uint256 ammPoolFeeRate,
        uint256 goalFeeRate
    );

    /// @notice Emitted when all 4 lottery tier configs are replaced atomically.
    event LotteryConfigsUpdated(uint16[12] flat);

    // ========================================================================
    // CUSTOM ERRORS
    // ========================================================================

    error OnlyRegistry();
    error NotGameEngine();
    error PlayerAlreadyExists(address player);
    error PlayerNotFound(address player);
    error InvalidAmount();
    error InvalidLotteryConfig();
    error InsufficientBalance(uint256 requested, uint256 available);
    error GameNotActive();
    error InvalidMove();
    error NotFinalizer();
    error InvalidGameConfig();
    error MaxChainIterationsExceeded(uint256 iterations);
    error InvalidTileType(uint8 tileType);
    error InsufficientLotteryDeposit(uint256 required, uint256 available);
    error InvalidLotteryTier(uint8 tier);
    error LotteryPoolEmpty(uint8 tier);
    error NoDiceLeft();
    error RoundNotCompleted();
    error RoundAlreadyCompleted();
    error NoBalanceToWithdraw();
    error ClaimGracePeriodNotExpired(address player, uint256 claimDeadline, uint256 currentTime);
    error InvalidDicePrice(uint256 expected, uint256 actual);
    error NoFeesToWithdraw();
    error TreasuryNotSet();
    error InvalidFeeConfig(uint256 totalRate);
    error MaxPlayersReached(uint256 maxPlayers);
    error NoRewardToClaim();
    error InvalidClaimIndex(uint256 index, uint256 length);
    error AlreadyClaimed(uint256 index);
    error RewardClaimExpired(uint256 deadline, uint256 currentTime);
    error ClaimDeadlineNotExpired(uint256 deadline, uint256 currentTime);
    error LegacyClaimRecord(uint256 index);
    error InvalidRewardTiers(uint256 totalPercentage);
    error TooManyRewardTiers(uint256 count, uint256 max);
    error InvalidClaimPeriod(uint256 period);
    error PlayerNotActive(address player);
    error PlayerProgressValueTooLarge(uint256 value);
    error MoveAlreadyPending();
    error NoPendingMove();
    error MoveNotReady();
    error ReentrantCall();
    // V12 season errors, raised in LeaderboardLib; declared here so they decode against this ABI.
    error SeasonNotOver(uint256 season);
    error SeasonValueTooLarge(uint256 value);
    error SeasonSettlementInProgress(uint256 processed);
    /// @dev A single reward wider than ClaimRecord.amount (uint96), raised in LeaderboardLib.
    error ClaimAmountTooLarge(uint256 amount);

    // ========================================================================
    // CONSTRUCTOR & INITIALIZER
    // ========================================================================

    /**
     * @dev Constructor disables initializers to prevent initialization attacks
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes a new game instance with given configuration
     * @dev This replaces the constructor for upgradeable contracts
     * @param _gameId Unique identifier from registry
     * @param _boardType Size of board (30, 50, or 100)
     * @param _templateVersion Template version used
     * @param _boardSeed Random seed for board generation
     * @param _registry Address of the registry that deployed this contract
     * @param _playerProgressSBT Address of PlayerProgressSBT contract
     * @param _usdcToken Address of USDC token contract
     * @param _ammPool Address of AMM pool for USDC ⇄ SGP swaps
     * @param _templateData Raw template data for board configuration (unused in V1, reserved for future use)
     */
    function initialize(
        uint256 _gameId,
        uint256 _boardType,
        uint256 _templateVersion,
        bytes32 _boardSeed,
        address _registry,
        address _playerProgressSBT,
        address _usdcToken,
        address _ammPool,
        bytes calldata _templateData
    ) public initializer {
        // Note: _templateData is reserved for future tile configuration
        // Suppresses unused parameter warning
        _templateData;
        __AccessControl_init();
        __Pausable_init();

        // Validate inputs
        if (
            _gameId == 0 ||
            _registry == address(0) ||
            _playerProgressSBT == address(0) ||
            _usdcToken == address(0) ||
            _ammPool == address(0)
        ) {
            revert InvalidGameConfig();
        }

        if (_boardType != 26 && _boardType != 51 && _boardType != 101) {
            revert InvalidGameConfig();
        }

        // Set initial roles — both Registry and its caller (deployer/admin) get admin
        // so the human operator can manage roles directly without routing through Registry.
        _grantRole(DEFAULT_ADMIN_ROLE, _registry);
        _grantRole(GAME_ENGINE_ROLE, _registry);
        if (tx.origin != _registry) {
            _grantRole(DEFAULT_ADMIN_ROLE, tx.origin);
        }

        // Store game configuration
        gameConfig = GameConfig({
            gameId: _gameId,
            boardType: _boardType,
            templateVersion: _templateVersion,
            boardSeed: _boardSeed,
            registry: _registry,
            creationTime: block.timestamp,
            gameActive: false, // Start inactive, will be activated by registry
            contractVersion: CONTRACT_VERSION
        });

        playerProgressSBT = _playerProgressSBT;
        usdcToken = IERC20(_usdcToken);
        ammPool = ISugorokuAMMPool(_ammPool);

        // Get SGP token address from AMM pool (token1 = SGP)
        sgpToken = ammPool.token1();

        // Initialize state variables
        totalDiceRolls = 0;

        // Initialize lottery configurations with simulation-confirmed rates
        _initializeLotteryConfigs();

        // Initialize fee configuration with defaults (V2)
        _initializeFeeConfig();

        // Initialize reward tiers with defaults (V3)
        _initializeRewardTiers();

        emit GameStatusChanged(_gameId, false, false, _registry);
    }

    /**
     * @notice Initializes fee configuration with default values
     * @dev Called during initialize(), can be updated later via setFeeConfig()
     */
    function _initializeFeeConfig() internal {
        dicePrice = DEFAULT_DICE_PRICE_USDC;
        platformFeeRate = DEFAULT_PLATFORM_FEE_RATE;
        leaderboardFeeRate = DEFAULT_LEADERBOARD_FEE_RATE;
        ammPoolFeeRate = DEFAULT_AMM_POOL_FEE_RATE;
    }

    /**
     * @notice Initializes default reward tiers for top 10 leaderboard distribution
     * @dev Exponential decay curve: top 3 receive 56%, remaining 7 receive 44%
     *      Each metric (Owned SGP, Earned SGP, Dice Purchased) gets 1/3 of total pool
     */
    function _initializeRewardTiers() internal {
        rewardClaimPeriod = DEFAULT_REWARD_CLAIM_PERIOD;
        LeaderboardLib.pushDefaultRewardTiers(rewardTiers);
    }

    /**
     * @notice Initializes lottery configurations with simulation-confirmed rates
     * @dev Called during initialize(), rates in basis points (100 = 1%)
     * Reference: docs/SIMULATION_CONFIG.md
     */
    function _initializeLotteryConfigs() internal {
        LeaderboardLib.initializeLotteryConfigs(lotteryConfigs);
    }

    /**
     * @notice Atomically replace all 4 lottery tier configs (Bronze, Silver,
     *         Gold, Jackpot). Caller passes a flat `uint16[12]` for ABI
     *         compatibility across Registry/library boundaries.
     * @dev Order: tier index 0..3 × (winRate, poolPayoutRate, lossStakeRate)
     *      Each rate is in basis points; must be <= 10000.
     */
    function setAllLotteryConfigs(uint16[12] calldata flat) external onlyRole(DEFAULT_ADMIN_ROLE) {
        LeaderboardLib.setLotteryConfigs(lotteryConfigs, flat);
        emit LotteryConfigsUpdated(flat);
    }

    // ========================================================================
    // VERSION INFO
    // ========================================================================

    /**
     * @notice Gets current contract version
     * @dev Marked virtual to allow override in upgraded implementations
     * @return Current version number
     */
    function getVersion() external pure virtual returns (uint256) {
        return CONTRACT_VERSION;
    }

    // ========================================================================
    // EXTERNAL FUNCTIONS - REGISTRY OPERATIONS
    // ========================================================================

    /**
     * @notice Activates the game (only callable by registry/admin)
     */
    function activateGame() external onlyRole(DEFAULT_ADMIN_ROLE) {
        bool oldStatus = gameConfig.gameActive;
        gameConfig.gameActive = true;

        emit GameStatusChanged(gameConfig.gameId, oldStatus, true, msg.sender);
    }

    /**
     * @notice Deactivates the game (only callable by registry/admin)
     */
    function deactivateGame() external onlyRole(DEFAULT_ADMIN_ROLE) {
        bool oldStatus = gameConfig.gameActive;
        gameConfig.gameActive = false;

        emit GameStatusChanged(gameConfig.gameId, oldStatus, false, msg.sender);
    }

    // ========================================================================
    // TILE CONFIGURATION
    // ========================================================================

    /**
     * @notice Configures a single tile at a specific position
     * @dev Only callable by admin before game activation
     * @dev Note: For lottery tiles, use configureTilesBatch to properly track positions
     * @param position Board position (0 to boardType-1)
     * @param tileType Type of tile
     * @param effectValue Movement effect value (for MOVE_FORWARD/BACKWARD)
     */
    function configureTile(
        uint256 position,
        TileType tileType,
        int16 effectValue
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        LeaderboardLib.configureTile(
            tiles,
            lotteryTilePositions,
            gameConfig.boardType,
            position,
            tileType,
            effectValue
        );
    }

    /**
     * @notice Batch configure tiles for gas efficiency
     * @dev Only callable by admin before game activation
     * @dev Also tracks lottery tile positions for pool management
     * @param positions Array of positions
     * @param tileTypes Array of tile types
     * @param effectValues Array of effect values
     */
    function configureTilesBatch(
        uint256[] calldata positions,
        TileType[] calldata tileTypes,
        int16[] calldata effectValues
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Validation and the writes run in LeaderboardLib (cold admin path)
        LeaderboardLib.configureTilesBatch(
            tiles,
            lotteryTilePositions,
            gameConfig.boardType,
            positions,
            tileTypes,
            effectValues
        );
    }

    /**
     * @notice Gets the tile configuration at a position
     * @param position Board position
     * @return Tile configuration
     */
    function getTile(uint256 position) external view returns (TileConfig memory) {
        return tiles[position];
    }

    /**
     * @notice Gets all tile configurations for the board
     * @return Array of tile configurations indexed by position
     */
    function getAllTiles() external view returns (TileConfig[] memory) {
        uint256 boardSize = gameConfig.boardType;
        TileConfig[] memory allTiles = new TileConfig[](boardSize);

        for (uint256 i = 0; i < boardSize; i++) {
            allTiles[i] = tiles[i];
        }

        return allTiles;
    }

    // ========================================================================
    // LOTTERY POOL MANAGEMENT
    // ========================================================================

    /// @notice Capability marker for direct USDC funding of undistributed leaderboard rewards.
    function manualFundingVersion() external pure returns (uint256) {
        return 1;
    }

    event LeaderboardFunded(address indexed funder, uint256 usdcAmount);

    /// @notice Pull admin USDC into the undistributed budget, without minting dice or claims.
    function fundLeaderboard(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        LeaderboardLib.fundBudget(LEADERBOARD_BUDGET_SLOT, address(usdcToken), amount, false);
    }

    event GoalTreasuryFunded(address indexed funder, uint256 usdcAmount);

    /// @notice Pull admin USDC into the goal treasury. Fee-on-transfer tokens are rejected.
    function fundGoalTreasury(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        LeaderboardLib.fundBudget(GOAL_TREASURY_USDC_SLOT, address(usdcToken), amount, true);
    }

    /**
     * @notice Adds SGP to a specific lottery tile's pool
     * @dev Only callable by game engine for pool contributions. Position 0 is the
     *      START_GOAL tile and reverts; the goal treasury is funded in USDC instead.
     * @param tilePosition Position of the lottery tile
     * @param amount SGP amount to add
     */
    function contributeLotteryPool(
        uint256 tilePosition,
        uint256 amount
    ) external onlyRole(GAME_ENGINE_ROLE) {
        // Position 0 never holds a pool, whatever tile type it is configured as.
        if (tilePosition == 0) revert InvalidLotteryTier(0);
        // Validate that the tile at this position is a lottery tile
        TileType tt = tiles[tilePosition].tileType;
        if (tt != TileType.LOTTERY_1 && tt != TileType.LOTTERY_2 && tt != TileType.LOTTERY_3) {
            revert InvalidLotteryTier(uint8(tt));
        }
        lotteryPools[tilePosition] += amount;
    }

    /**
     * @notice Gets the current balance of a lottery pool by tile position
     * @param tilePosition Position of the lottery tile
     * @return Pool balance
     */
    function getLotteryPool(uint256 tilePosition) external view returns (uint256) {
        return lotteryPools[tilePosition];
    }

    /**
     * @notice Gets all lottery pool balances (by tile position)
     * @return positions Array of lottery tile positions
     * @return balances Array of pool balances (corresponding to positions)
     */
    function getAllLotteryPools()
        external
        view
        returns (uint256[] memory positions, uint256[] memory balances)
    {
        uint256 numPools = lotteryTilePositions.length;
        positions = new uint256[](numPools);
        balances = new uint256[](numPools);

        for (uint256 i = 0; i < numPools; i++) {
            positions[i] = lotteryTilePositions[i];
            balances[i] = lotteryPools[lotteryTilePositions[i]];
        }

        return (positions, balances);
    }

    /**
     * @notice Gets lottery configuration for a tier
     * @param tier Lottery tier (0=Bronze, 1=Silver, 2=Gold, 3=Jackpot)
     * @return Lottery configuration
     */
    function getLotteryConfig(uint8 tier) external view returns (LotteryConfig memory) {
        if (tier > 3) {
            revert InvalidLotteryTier(tier);
        }
        return lotteryConfigs[tier];
    }

    // ========================================================================
    // PLAYER MANAGEMENT
    // ========================================================================

    /**
     * @notice Registers a player for the gift-dice path (DiceNFTRedeemer.redeemAndJoin)
     * @param player Address of the player to add
     * @return startPosition Starting position (always 0)
     * @dev Players join with joinGame. This entry point registers a player with no dice,
     *      and a dice-less player can never reach the goal, never exit, and holds a slot
     *      forever. So only REDEEMER_ROLE may call it, and a holder must follow it with
     *      grantDice in the same transaction, as DiceNFTRedeemer.redeemAndJoin does. The
     *      contract does not enforce that pairing, so the role is a trusted one: the
     *      redeemer permanently, an operator only for the length of a restore-stranded-dice
     *      run, and never the Registry, which must not relay other callers to it (its old
     *      addPlayerToGame pass-through did, until #276 removed it).
     *      whenNotPaused also stops a temporary restore operator from registering players
     *      during a pause, when no grantDice could follow.
     */
    function addPlayer(
        address player
    ) external onlyRole(REDEEMER_ROLE) whenNotPaused returns (uint256 startPosition) {
        return _addPlayer(player);
    }

    function _addPlayer(address player) internal returns (uint256 startPosition) {
        // Check game is active
        if (!gameConfig.gameActive) {
            revert GameNotActive();
        }

        if (player == address(0)) {
            revert InvalidGameConfig();
        }

        if (players[player].active) {
            revert PlayerAlreadyExists(player);
        }

        // Check max players limit
        if (playerCount >= MAX_PLAYERS) {
            revert MaxPlayersReached(MAX_PLAYERS);
        }

        // Create player record with 0 initial balances
        // Players get SGP by buying dice with USDC (via addDice)
        players[player] = Player({
            playerAddress: player,
            position: 0, // Start at position 0
            sgpBalance: 0,
            goalUsdcPending: 0,
            gameSGPBalance: 0, // Starts at 0, increases when buying dice
            lastMoveTime: block.timestamp,
            active: true,
            roundCompleted: false,
            totalMoves: 0,
            diceCount: 0,
            totalSgpEarned: 0,
            totalSgpLost: 0,
            claimDeadline: 0
        });

        // A returning player may still have stale Owned SGP from a pre-upgrade exit.
        _syncPlayerProgress(player, 0, 0, 0, 0);

        // Add to player addresses array and track index for O(1) removal
        playerIndexInArray[player] = playerAddresses.length;
        playerAddresses.push(player);
        playerCount++;

        emit PlayerJoined(player, 0, 0, block.timestamp);

        return 0; // Starting position
    }

    /**
     * @notice Adds dice to a player (called by registry after dice purchase)
     * @dev Updates player dice count and lottery deposit; reverts after the goal (see _addDiceInternal)
     * @param player Player address
     * @param diceAmount Number of dice to add
     * @param sgpAmount SGP amount received from dice purchase (adds to lottery deposit)
     */
    function addDice(
        address player,
        uint256 diceAmount,
        uint256 sgpAmount
    ) external onlyRole(GAME_ENGINE_ROLE) {
        Player storage playerData = players[player];
        if (!playerData.active) {
            revert PlayerNotFound(player);
        }

        _addDiceInternal(player, diceAmount, sgpAmount, 0, false);
    }

    /**
     * @notice Buy dice with USDC (player-facing function)
     * @dev Fees split before the AMM swap: platform, leaderboard and goal shares stay in
     *      USDC and the remainder (including rounding dust) is swapped for the player
     * @param diceAmount Number of dice to buy
     * @param usdcAmount Amount of USDC to spend (must be exactly diceAmount * 10 USDC)
     */
    function buyDice(uint256 diceAmount, uint256 usdcAmount) external whenNotPaused {
        _buyDice(msg.sender, diceAmount, usdcAmount);
    }

    /**
     * @notice Atomic join: register as a player AND buy `diceAmount` dice in
     *         one transaction. Required USDC is computed from `dicePrice`, so
     *         any revert inside either leg rolls the whole thing back.
     * @dev Caller (the new player) must have approved enough USDC to this
     *      GameBoard contract before calling. One approve + one joinGame = 2 txs.
     */
    function joinGame(uint256 diceAmount) external whenNotPaused {
        if (diceAmount == 0) {
            revert InvalidAmount();
        }
        _addPlayer(msg.sender);
        _buyDice(msg.sender, diceAmount, diceAmount * dicePrice);
    }

    function _buyDice(address player, uint256 diceAmount, uint256 usdcAmount) internal {
        Player storage playerData = players[player];
        if (!playerData.active) {
            revert PlayerNotFound(player);
        }

        if (diceAmount == 0) {
            revert InvalidAmount();
        }

        // V2: Enforce configurable dice price
        uint256 requiredUsdc = diceAmount * dicePrice;
        if (usdcAmount != requiredUsdc) {
            revert InvalidDicePrice(requiredUsdc, usdcAmount);
        }

        // Transfer USDC from player to GameBoard
        usdcToken.safeTransferFrom(player, address(this), usdcAmount);

        // V2: Calculate fee splits using configurable rates (applied to USDC before AMM swap)
        uint256 platformFee = (usdcAmount * platformFeeRate) / BASIS_POINTS;
        uint256 leaderboardFee = (usdcAmount * leaderboardFeeRate) / BASIS_POINTS;
        uint256 goalFee = (usdcAmount * goalFeeRate) / BASIS_POINTS;
        uint256 commission = platformFee + leaderboardFee + goalFee;
        uint256 ammAmount = usdcAmount - commission;

        // Accumulate fees (in USDC)
        platformFeeAccumulated += platformFee;
        leaderboardFeeAccumulated += leaderboardFee;
        goalTreasuryUsdc += goalFee;

        // Approve AMM pool to spend only the AMM portion
        usdcToken.forceApprove(address(ammPool), ammAmount);

        // Swap USDC for per-game token via AMM pool (player gets variable amount based on rate)
        uint256 sgpReceived = ammPool.swap(ammAmount, 0, address(usdcToken), address(this));

        // Add dice with ALL tokens received (no additional commission in V2)
        _addDiceInternal(player, diceAmount, sgpReceived, leaderboardFee, false);

        // Track total USDC collected
        totalUsdcPool += usdcAmount;

        emit DicePurchased(player, diceAmount, sgpReceived, commission, block.timestamp);
    }

    /**
     * @notice Internal function to add dice (bypasses role check for buyDice)
     * @dev Shared by addDice, buyDice/joinGame and grantDice. Reverts with
     *      RoundAlreadyCompleted after the goal: the player can only claim, so the
     *      dice could never be rolled and would be forfeited at exit. In _buyDice this
     *      runs after the USDC pull and swap; the revert rolls those back (a second,
     *      earlier check does not fit under EIP-170).
     *      Granted dice (V12) bring no tokens and count in no ranking: they only raise
     *      freeDiceCount, which requestMove spends before paid dice.
     * @param leaderboardShare Leaderboard USDC of this purchase, credited to the season
     * @param granted True for grantDice
     */
    function _addDiceInternal(
        address player,
        uint256 diceAmount,
        uint256 sgpAmount,
        uint256 leaderboardShare,
        bool granted
    ) internal {
        Player storage playerData = players[player];
        if (playerData.roundCompleted) {
            revert RoundAlreadyCompleted();
        }
        playerData.diceCount += diceAmount;
        if (granted) {
            freeDiceCount[player] += diceAmount;
            return;
        }
        playerData.gameSGPBalance += sgpAmount;
        totalSgpPool += sgpAmount;

        _syncPlayerProgress(
            player,
            playerData.gameSGPBalance,
            0,
            diceAmount,
            leaderboardShare
        );
    }

    // ========================================================================
    // EXTERNAL DICE GRANT (for DiceNFT Redeemer)
    // ========================================================================

    /**
     * @notice Grant dice to an active player without USDC payment
     * @dev Only callable by addresses with REDEEMER_ROLE (e.g., DiceNFTRedeemer contract).
     *      Reverts with RoundAlreadyCompleted after the goal, so a redemption burns nothing.
     *      Since V12 these dice count in no ranking, and neither do the rolls that use them.
     * @param player Address of the player to grant dice to
     * @param diceAmount Number of dice to grant
     */
    function grantDice(
        address player,
        uint256 diceAmount
    ) external onlyRole(REDEEMER_ROLE) whenNotPaused {
        if (!players[player].active) {
            revert PlayerNotActive(player);
        }
        if (diceAmount == 0) {
            revert InvalidAmount();
        }
        _addDiceInternal(player, diceAmount, 0, 0, true);
        emit DiceGranted(player, diceAmount, block.timestamp);
    }

    // ========================================================================
    // FEE MANAGEMENT (V2)
    // ========================================================================

    /**
     * @notice Set the treasury address for platform fee withdrawals
     * @dev Only callable by admin
     * @param _treasury New treasury address
     */
    function setTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        LeaderboardLib.setTreasury(TREASURY_SLOT, _treasury);
    }

    /**
     * @notice Send the accumulated platform fees (USDC) and operator tokens to treasury
     * @dev Only callable by admin. 1 wei of the token accrual stays on the board to keep
     *      later lottery losses off the zero-to-nonzero write. Reverts when nothing would be
     *      sent, or when treasury is this board.
     * @return amount Amount of USDC withdrawn
     */
    function withdrawPlatformFees() external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 amount) {
        return
            LeaderboardLib.withdrawOperatorFees(
                PLATFORM_FEE_SLOT,
                OPERATOR_TOKEN_SLOT,
                treasury,
                address(usdcToken),
                address(sgpToken)
            );
    }

    /**
     * @notice Withdraw accumulated leaderboard fees
     * @dev Only callable by admin, can be distributed to leaderboard winners
     * @return amount Amount of USDC withdrawn
     */
    function withdrawLeaderboardFees()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 amount)
    {
        amount = leaderboardFeeAccumulated;
        if (amount == 0) {
            revert NoFeesToWithdraw();
        }

        leaderboardFeeAccumulated = 0;
        usdcToken.safeTransfer(msg.sender, amount);

        emit LeaderboardFeesWithdrawn(msg.sender, amount);
    }

    /**
     * @notice Get current accumulated fees
     * @return platformFees Accumulated platform fees in USDC
     * @return leaderboardFees Accumulated leaderboard fees in USDC
     */
    function getAccumulatedFees()
        external
        view
        returns (uint256 platformFees, uint256 leaderboardFees)
    {
        return (platformFeeAccumulated, leaderboardFeeAccumulated);
    }

    /**
     * @notice Update fee configuration
     * @dev Only callable by admin. Fee rates must sum to BASIS_POINTS (10000 = 100%)
     * @param _dicePrice New dice price in USDC (6 decimals)
     * @param _platformFeeRate New platform fee rate (basis points)
     * @param _leaderboardFeeRate New leaderboard fee rate (basis points)
     * @param _ammPoolFeeRate New AMM pool fee rate (basis points)
     * @param _goalFeeRate New goal treasury fee rate (basis points)
     */
    function setFeeConfig(
        uint256 _dicePrice,
        uint256 _platformFeeRate,
        uint256 _leaderboardFeeRate,
        uint256 _ammPoolFeeRate,
        uint256 _goalFeeRate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Validation, the writes and FeeConfigUpdated run in LeaderboardLib (cold path)
        LeaderboardLib.setFeeConfig(
            DICE_PRICE_SLOT,
            GOAL_FEE_RATE_SLOT,
            _dicePrice,
            _platformFeeRate,
            _leaderboardFeeRate,
            _ammPoolFeeRate,
            _goalFeeRate
        );
    }

    // ========================================================================
    // GAME EXIT
    // ========================================================================

    /**
     * @notice Exit the game: swap the game-token balance to USDC and pay any goal bonus
     * @dev Player must have completed at least one round (landed on goal tile at position 0)
     * @return usdcReceived USDC received from the swap (excludes the goal bonus)
     */
    function exitGame() external whenNotPaused returns (uint256 usdcReceived) {
        return _exit(msg.sender, false);
    }

    /**
     * @notice Force-claim on behalf of a player whose grace period has expired
     * @dev Callable by `player` or a FINALIZER_ROLE holder (the keeper) after the player's
     *      claimDeadline has passed. A forced exit removes the player from the roster the
     *      leaderboard ranks, so an outsider must not be able to drop a rival just before a
     *      jackpot move settles. USDC is sent to the player, not the caller.
     * @param player Address of the player to force-claim for
     * @return usdcReceived USDC the player received from the swap (excludes the goal bonus)
     */
    function exitGameFor(address player) external whenNotPaused returns (uint256 usdcReceived) {
        _requirePlayerOrFinalizer(player);
        return _exit(player, true);
    }

    /**
     * @dev Gate for actions on another player's behalf (finalizeMove, exitGameFor): only
     *      `player` or a FINALIZER_ROLE holder. Both change what a jackpot ranking sees.
     */
    function _requirePlayerOrFinalizer(address player) private view {
        if (msg.sender != player && !hasRole(FINALIZER_ROLE, msg.sender)) revert NotFinalizer();
    }

    /**
     * @dev Shared exit. All player state is cleared before the swap and the bonus
     *      transfer, so a re-entrant call finds no active player.
     */
    function _exit(address player, bool forced) private returns (uint256 usdcReceived) {
        if (EXIT_LOCK.asBoolean().tload()) revert ReentrantCall();
        EXIT_LOCK.asBoolean().tstore(true);
        Player storage playerData = players[player];

        if (!playerData.active) {
            revert PlayerNotFound(player);
        }
        _requireNoPendingMove(player);

        // Player must have completed at least one round (landed on goal)
        if (!playerData.roundCompleted) {
            revert RoundNotCompleted();
        }

        if (forced && block.timestamp < playerData.claimDeadline) {
            revert ClaimGracePeriodNotExpired(player, playerData.claimDeadline, block.timestamp);
        }

        uint256 sgpBalance = playerData.gameSGPBalance;
        uint256 goalBonus = playerData.goalUsdcPending;
        // A won NFT (V13): GoalRewardLib keeps the prize contract holding it in bytes 2..21
        // of the slot with `active` and `roundCompleted`. `delete players[player]` clears it.
        address nftPrize;
        assembly ("memory-safe") {
            nftPrize := and(
                shr(16, sload(add(playerData.slot, 6))),
                0xffffffffffffffffffffffffffffffffffffffff
            )
        }
        if (sgpBalance == 0 && goalBonus == 0 && nftPrize == address(0)) {
            revert NoBalanceToWithdraw();
        }

        // Stored before the reset, for the event and the leaderboard
        uint256 totalEarned = playerData.totalSgpEarned;

        if (totalSgpPool >= sgpBalance) {
            totalSgpPool -= sgpBalance;
        } else {
            totalSgpPool = 0;
        }

        // Remove player from playerAddresses array using swap-and-pop (O(1))
        uint256 indexToRemove = playerIndexInArray[player];
        uint256 lastIndex = playerAddresses.length - 1;

        if (indexToRemove != lastIndex) {
            address lastPlayer = playerAddresses[lastIndex];
            playerAddresses[indexToRemove] = lastPlayer;
            playerIndexInArray[lastPlayer] = indexToRemove;
        }

        playerAddresses.pop();
        delete playerIndexInArray[player];

        // Owned SGP represents the current in-game balance, which is zero after exit.
        _syncPlayerProgress(player, 0, 0, 0, 0);

        // Delete player data completely (allows rejoining). History lives in the SBT.
        delete players[player];
        // Unrolled granted dice go with the rest of the dice.
        delete freeDiceCount[player];

        if (playerCount > 0) {
            playerCount--;
        }

        if (sgpBalance != 0) {
            // minAmountOut 0 accepts any slippage (frontend can add protection)
            sgpToken.forceApprove(address(ammPool), sgpBalance);
            usdcReceived = ammPool.swap(sgpBalance, 0, address(sgpToken), player);
        }

        if (goalBonus != 0) {
            usdcToken.safeTransfer(player, goalBonus);
            emit GoalBonusPaid(player, goalBonus);
        }

        // Sends the NFT from the prize wallet; a failed send becomes an open claim there
        // and does not revert the exit.
        if (nftPrize != address(0)) {
            IGoalNftPrizes(nftPrize).deliver(player);
        }

        emit GameExited(
            player,
            sgpBalance,
            usdcReceived,
            totalEarned,
            forced ? "auto_claimed" : "round_completed"
        );
        EXIT_LOCK.asBoolean().tstore(false);
    }

    /**
     * @notice Returns addresses of players whose claim grace period has expired
     * @dev Used by keeper/cron to find players eligible for force-claim
     * @return claimable Array of player addresses that can be force-claimed
     */
    function getClaimablePlayers() external view returns (address[] memory claimable) {
        return
            LeaderboardLib.getClaimablePlayers(playerAddresses, players, pendingMoveTargetBlocks);
    }

    /**
     * @notice Consumes one dice and fixes the future block used for this move's entropy
     * @dev The target is the block after the request is included, so its hash cannot be
     *      known during pre-signature simulation of this transaction.
     */
    function requestMove() external whenNotPaused {
        if (!gameConfig.gameActive) {
            revert GameNotActive();
        }

        address player = msg.sender;
        Player storage playerData = players[player];
        if (!playerData.active) {
            revert PlayerNotFound(player);
        }
        if (playerData.diceCount == 0) {
            revert NoDiceLeft();
        }
        if (pendingMoveTargetBlocks[player] != 0) {
            revert MoveAlreadyPending();
        }

        totalDiceRolls++;
        uint256 targetBlock = block.number + 1;
        playerData.diceCount--;
        // Granted dice are rolled first (V12). Which kind of die this move uses is fixed
        // here, before its outcome exists, so a grant that lands while the move is pending
        // cannot turn it into a free roll. No move is pending, so bit 255 is clear.
        uint256 freeDice = freeDiceCount[player];
        if (freeDice != 0) freeDiceCount[player] = (freeDice - 1) | FREE_MOVE_PENDING;
        pendingMoveTargetBlocks[player] = targetBlock;

        emit MoveRequested(player, targetBlock);
    }

    /**
     * @notice Settles a requested move after its fixed target block has been mined
     * @dev Callable by `player` or a FINALIZER_ROLE holder (the keeper); all state changes
     *      apply to `player`. Settlement order decides which changes a jackpot ranking sees, so
     *      an outsider must not be able to settle a rival's move just before a jackpot move.
     *      If the target block hash is no longer reachable, the move is released
     *      (StrandedMoveReset) and its dice is forfeited, not refunded.
     */
    function finalizeMove(
        address player
    )
        external
        whenNotPaused
        returns (uint256 finalPosition, uint256 diceRoll, uint256 sgpEarned, uint256 sgpLost)
    {
        _requirePlayerOrFinalizer(player);
        uint256 targetBlock = pendingMoveTargetBlocks[player];
        if (targetBlock == 0) {
            revert NoPendingMove();
        }
        if (block.number <= targetBlock) {
            revert MoveNotReady();
        }

        Player storage playerData = players[player];
        if (!playerData.active) {
            revert PlayerNotFound(player);
        }
        // A move requested with a free die (V12) wins nothing for any ranking. The flag
        // clears on a stranded move too; its die was spent at requestMove either way.
        uint256 freeDice = freeDiceCount[player];
        if (freeDice >= FREE_MOVE_PENDING) freeDiceCount[player] = freeDice - FREE_MOVE_PENDING;
        bytes32 targetBlockHash = _blockHashOrZero(targetBlock);
        if (targetBlockHash == bytes32(0)) {
            // The hash has aged out of both BLOCKHASH and the BEP-440 precompile,
            // so this roll can never be derived by anyone. Clear the slot, which
            // would otherwise block requestMove and exitGame for this player
            // permanently. The dice requestMove spent is forfeited, not refunded:
            // a refund would let a player preview the roll with eth_call, withhold
            // a bad one until its hash ages out, and re-roll for free. Admins can
            // restore genuine losses from StrandedMoveReset logs via grantDice
            // (scripts/operations/restore-stranded-dice.ts). The target block is
            // already mined (checked above), so the outcome is unknowable here
            // rather than merely not ready.
            delete pendingMoveTargetBlocks[player];
            emit StrandedMoveReset(player, targetBlock);
            return (playerData.position, 0, 0, 0);
        }
        bytes32 entropy = keccak256(
            abi.encodePacked(targetBlockHash, address(this), player, playerData.totalMoves)
        );
        uint256 startPosition = playerData.position;
        diceRoll = (uint256(entropy) % 6) + 1;

        // Delete before any external interaction in tile processing. A revert restores it.
        delete pendingMoveTargetBlocks[player];

        uint256 currentPosition = startPosition + diceRoll;

        if (currentPosition >= gameConfig.boardType) {
            currentPosition = currentPosition % gameConfig.boardType;
        }

        playerData.position = currentPosition;
        playerData.lastMoveTime = block.timestamp;
        playerData.totalMoves++;

        // Dice landing on 0 is always forward movement, so it completes the round
        if (currentPosition == 0) {
            _completeRound(playerData, player, entropy, 0);
        }

        (finalPosition, sgpEarned, sgpLost) = _processChainedEffects(
            currentPosition,
            player,
            entropy
        );

        if (sgpEarned != 0 || sgpLost != 0) {
            // Winnings count in the season this move is settled in.
            _syncPlayerProgress(
                player,
                playerData.gameSGPBalance,
                freeDice >= FREE_MOVE_PENDING ? 0 : sgpEarned,
                0,
                0
            );
        }

        emit PlayerMoved(player, finalPosition, diceRoll, sgpEarned, sgpLost, block.timestamp);

        return (finalPosition, diceRoll, sgpEarned, sgpLost);
    }

    /**
     * @notice Processes chained tile effects
     * @dev Helper to reduce stack depth in movePlayer
     * @param startPosition Starting position
     * @param player Player address
     * @return finalPosition Final position after all effects
     * @return sgpEarned Total SGP earned
     * @return sgpLost Total SGP lost
     */
    function _processChainedEffects(
        uint256 startPosition,
        address player,
        bytes32 entropy
    ) internal returns (uint256 finalPosition, uint256 sgpEarned, uint256 sgpLost) {
        int256 totalSgpChange;
        uint256 currentPosition = startPosition;

        // Process tile effects - may chain for movement tiles
        for (uint256 i = 0; i < MAX_CHAIN_ITERATIONS; i++) {
            (uint256 newPos, int256 sgpChange) = _processTileEffect(
                currentPosition,
                player,
                entropy,
                i
            );

            totalSgpChange += sgpChange;

            // Check if position changed (movement tile)
            if (newPos != currentPosition) {
                emit ChainedMovement(player, currentPosition, newPos, i);
                currentPosition = newPos;
            } else {
                // No more movement, exit loop
                break;
            }

            // Safety check at end of loop
            if (i == MAX_CHAIN_ITERATIONS - 1) {
                revert MaxChainIterationsExceeded(i + 1);
            }
        }

        finalPosition = currentPosition;

        // Calculate sgpEarned and sgpLost from totalSgpChange
        if (totalSgpChange >= 0) {
            sgpEarned = uint256(totalSgpChange);
            sgpLost = 0;
        } else {
            sgpEarned = 0;
            sgpLost = uint256(-totalSgpChange);
        }

        return (finalPosition, sgpEarned, sgpLost);
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /**
     * @notice Gets player information
     * @param player Address of the player
     * @return Player struct with player data
     */
    function getPlayer(address player) external view returns (Player memory) {
        return players[player];
    }

    /**
     * @notice Gets all players in the game
     * @return Array of player addresses
     */
    function getAllPlayers() external view returns (address[] memory) {
        return playerAddresses;
    }

    /**
     * @notice Returns all players with their current state in a single call
     * @dev Replaces getAllPlayers() + N × getPlayer() fan-out pattern.
     *      Uses warm storage reads after the first player (100 gas vs 2100 cold).
     *      For 300 players: ~300 × 8 fields × 100 gas = ~240k gas (well within eth_call limits).
     * @return Array of PlayerView structs with essential player data
     */
    function getAllPlayersWithData() external view returns (PlayerView[] memory) {
        uint256 len = playerAddresses.length;
        PlayerView[] memory result = new PlayerView[](len);
        for (uint256 i = 0; i < len; i++) {
            Player storage p = players[playerAddresses[i]];
            result[i] = PlayerView({
                playerAddress: p.playerAddress,
                position: p.position,
                gameSGPBalance: p.gameSGPBalance,
                diceCount: p.diceCount,
                active: p.active,
                roundCompleted: p.roundCompleted,
                totalSgpEarned: p.totalSgpEarned,
                lastMoveTime: p.lastMoveTime
            });
        }
        return result;
    }

    /**
     * @notice Checks if a player is in the game
     * @param player Address to check
     * @return True if player exists and is active
     */
    function hasPlayer(address player) external view returns (bool) {
        return players[player].active;
    }

    /**
     * @notice Gets current game configuration
     * @return Game configuration struct
     */
    function getGameConfig() external view returns (GameConfig memory) {
        return gameConfig;
    }

    /**
     * @notice Gets game statistics
     * @return totalPlayers Number of players in game
     * @return totalSgpPool_ Total SGP in game pool
     * @return totalJackpot_ Total jackpot across all lottery pools
     * @return totalDiceRolls_ Total dice rolls made
     * @return gameActive Current game status
     * @return boardSize Number of tiles on the board
     */
    function getGameStats()
        external
        view
        returns (
            uint256 totalPlayers,
            uint256 totalSgpPool_,
            uint256 totalJackpot_,
            uint256 totalDiceRolls_,
            bool gameActive,
            uint256 boardSize
        )
    {
        return (
            playerCount,
            totalSgpPool,
            getTotalJackpot(),
            totalDiceRolls,
            gameConfig.gameActive,
            gameConfig.boardType
        );
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /**
     * @notice Loads a past block hash, or zero when it is no longer reachable
     * @dev BLOCKHASH reaches 256 blocks and the BEP-440 precompile a few thousand
     *      more; past that the hash is gone for good. Zero doubles as "unavailable"
     *      because a real block hash is never zero.
     */
    function _blockHashOrZero(uint256 targetBlock) internal view returns (bytes32 result) {
        result = blockhash(targetBlock);
        if (result != bytes32(0)) {
            return result;
        }

        bool valid;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, targetBlock)
            let success := staticcall(gas(), BLOCK_HASH_HISTORY, ptr, 0x20, ptr, 0x20)
            valid := and(success, eq(returndatasize(), 0x20))
            result := mload(ptr)
        }
        if (!valid) {
            result = bytes32(0);
        }
    }

    function _deriveRandom(
        bytes32 entropy,
        uint256 domain,
        uint256 effectIndex,
        uint256 position
    ) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(entropy, domain, effectIndex, position)));
    }

    function _requireNoPendingMove(address player) internal view {
        if (pendingMoveTargetBlocks[player] != 0) {
            revert MoveAlreadyPending();
        }
    }

    /**
     * @notice Processes tile effects based on tile type
     * @dev Main routing function for all tile effects - matches backend logic exactly
     * @param position Current position on board
     * @param player Player address
     * @return newPosition Position after effects (may differ from input for movement tiles)
     * @return sgpChange Change in SGP (positive=gain, negative=loss)
     */
    function _processTileEffect(
        uint256 position,
        address player,
        bytes32 entropy,
        uint256 effectIndex
    ) internal returns (uint256 newPosition, int256 sgpChange) {
        TileConfig storage tile = tiles[position];
        newPosition = position;
        sgpChange = 0;

        // START_GOAL and BLANK tiles have no effect
        if (tile.tileType == TileType.BLANK || tile.tileType == TileType.START_GOAL) {
            return (newPosition, sgpChange);
        }

        // Movement tiles (MOVE_FORWARD and MOVE_BACKWARD)
        if (tile.tileType == TileType.MOVE_FORWARD || tile.tileType == TileType.MOVE_BACKWARD) {
            int16 effectValue = tile.effectValue;
            if (tile.tileType == TileType.MOVE_BACKWARD) {
                effectValue = -effectValue; // Make negative for backward movement
            }
            newPosition = _processMovementTile(position, effectValue, player, entropy, effectIndex);
            emit TileEffectProcessed(
                player,
                position,
                tile.tileType,
                int256(effectValue),
                block.timestamp
            );
        }
        // Lottery tiles (LOTTERY_1, LOTTERY_2, LOTTERY_3)
        else if (tile.tileType >= TileType.LOTTERY_1 && tile.tileType <= TileType.LOTTERY_3) {
            sgpChange = _processLotteryTile(tile.tileType, player, entropy, effectIndex);
        }
        // Jackpot tile
        else if (tile.tileType == TileType.JACKPOT) {
            sgpChange = _processJackpotTile(player, entropy, effectIndex);
        }
        // CHALLENGE tile - reserved for future use
        // else if (tile.tileType == TileType.CHALLENGE) { }

        return (newPosition, sgpChange);
    }

    /**
     * @notice Processes movement tile effects (MOVE_FORWARD/BACKWARD)
     * @dev Handles position bounds and round completion detection
     * @param currentPosition Current player position
     * @param effect Movement amount (positive=forward, negative=backward)
     * @param player Player address
     * @return newPosition Final position after movement
     */
    function _processMovementTile(
        uint256 currentPosition,
        int16 effect,
        address player,
        bytes32 entropy,
        uint256 effectIndex
    ) internal returns (uint256 newPosition) {
        uint256 boardSize = gameConfig.boardType;
        int256 newPosInt = int256(currentPosition) + int256(effect);

        // Handle backward movement below 0 - clamp to 0
        if (newPosInt < 0) {
            newPosition = 0;
        }
        // Handle forward movement past board end - wrap around
        else if (uint256(newPosInt) >= boardSize) {
            newPosition = uint256(newPosInt) % boardSize;
        } else {
            newPosition = uint256(newPosInt);
        }

        // Reaching 0 counts as finishing the lap only when the player got there
        // going forward. A backward tile that lands on 0 — or overshoots and is
        // clamped there — has returned them to the start line, not carried them
        // to the goal, and must not unlock exitGame or start the keeper clock.
        if (newPosition == 0 && effect > 0) {
            _completeRound(players[player], player, entropy, effectIndex);
        }

        // Update player position
        players[player].position = newPosition;
    }

    /**
     * @notice Marks the round complete and draws the goal reward, held until the player exits:
     *         a share of the USDC goal treasury, or (V13, with an odds table) an NFT prize
     * @dev No-op after the first completion of this entry (rejoining resets the flag). The
     *      draw lives in GoalRewardLib for bytecode. The bonus is USDC, so it touches neither
     *      the game-token balance nor Earned SGP, the SBT or the season stats.
     */
    function _completeRound(
        Player storage playerData,
        address player,
        bytes32 entropy,
        uint256 effectIndex
    ) internal {
        if (!playerData.roundCompleted) {
            GoalRewardLib.completeRound(playerData, player, entropy, effectIndex);
        }
    }

    /**
     * @notice Processes lottery tile (LOTTERY_1, LOTTERY_2, LOTTERY_3)
     * @dev Each lottery tile has its own pool, keyed by tile position
     * @param lotteryType Type of lottery tile (for config lookup)
     * @param player Player address
     * @return sgpChange Amount won (positive) or lost (negative)
     */
    function _processLotteryTile(
        TileType lotteryType,
        address player,
        bytes32 entropy,
        uint256 effectIndex
    ) internal returns (int256 sgpChange) {
        Player storage playerData = players[player];
        uint256 tilePosition = playerData.position;

        // Get lottery tier index for config (0=Bronze, 1=Silver, 2=Gold)
        uint8 tierIndex = uint8(lotteryType) - uint8(TileType.LOTTERY_1);
        LotteryConfig memory config = lotteryConfigs[tierIndex];

        // Use tile POSITION as pool key (each lottery tile has its own pool)
        uint256 poolBalance = lotteryPools[tilePosition];

        uint256 random = _deriveRandom(entropy, LOTTERY_RANDOM_DOMAIN, effectIndex, tilePosition) %
            10000;
        bool won = random < config.winRate;

        if (won) {
            // Calculate winnings: (poolBalance * poolPayoutRate) / 10000
            uint256 winnings = (poolBalance * config.poolPayoutRate) / 10000;

            if (winnings > 0) {
                // Deduct from THIS tile's pool
                lotteryPools[tilePosition] -= winnings;

                // Add to player's game SGP balance (matches backend - gameSGPBalance is the active balance)
                playerData.gameSGPBalance += winnings;
                playerData.totalSgpEarned += winnings;

                sgpChange = int256(winnings);
            }

            emit LotteryPlayed(player, lotteryType, true, 0, winnings, lotteryPools[tilePosition]);
            emit TileEffectProcessed(player, tilePosition, lotteryType, sgpChange, block.timestamp);
        } else {
            // Calculate loss: (gameSGPBalance * lossStakeRate) / 10000
            // Loss is calculated from game SGP balance (matches backend logic)
            uint256 lossAmount = (playerData.gameSGPBalance * config.lossStakeRate) / 10000;

            // Handle insufficient balance
            if (playerData.gameSGPBalance < lossAmount) {
                lossAmount = playerData.gameSGPBalance;
            }

            if (lossAmount > 0) {
                // Deduct from player's game balance
                playerData.gameSGPBalance -= lossAmount;
                playerData.totalSgpLost += lossAmount;

                // Accrue OPERATOR_TOKEN_SHARE_BPS to the operator, the rest to THIS tile's pool
                uint256 toOperator = (lossAmount * OPERATOR_TOKEN_SHARE_BPS) / BASIS_POINTS;
                lotteryPools[tilePosition] += lossAmount - toOperator;
                operatorTokenAccrued += toOperator;

                sgpChange = -int256(lossAmount);
            }

            emit LotteryPlayed(
                player,
                lotteryType,
                false,
                lossAmount,
                0,
                lotteryPools[tilePosition]
            );
            emit TileEffectProcessed(player, tilePosition, lotteryType, sgpChange, block.timestamp);
        }

        return sgpChange;
    }

    /**
     * @notice Processes jackpot tile
     * @dev Aggregates all pools, processes win, reseeds pools on win
     * @param player Player address
     * @return sgpChange Amount won (positive) or 0 (no loss on jackpot)
     */
    function _processJackpotTile(
        address player,
        bytes32 entropy,
        uint256 effectIndex
    ) internal returns (int256 sgpChange) {
        LotteryConfig memory config = lotteryConfigs[3]; // Jackpot config at index 3
        uint256 totalJackpot = getTotalJackpot();

        // Empty jackpot = no effect
        if (totalJackpot == 0) {
            emit TileEffectProcessed(
                player,
                players[player].position,
                TileType.JACKPOT,
                0,
                block.timestamp
            );
            return 0;
        }

        uint256 random = _deriveRandom(
            entropy,
            JACKPOT_RANDOM_DOMAIN,
            effectIndex,
            players[player].position
        ) % 10000;
        bool won = random < config.winRate; // 500 = 5% chance

        if (!won) {
            // No penalty on jackpot loss (lossStakeRate = 0)
            emit LotteryPlayed(player, TileType.JACKPOT, false, 0, 0, totalJackpot);
            emit TileEffectProcessed(
                player,
                players[player].position,
                TileType.JACKPOT,
                0,
                block.timestamp
            );
            return 0;
        }

        // Calculate player payout (50% of total)
        uint256 playerPayout = (totalJackpot * config.poolPayoutRate) / 10000;
        uint256 reseedTotal = totalJackpot - playerPayout;

        Player storage playerData = players[player];

        // Add payout to player's game SGP balance (matches backend - gameSGPBalance is the active balance)
        playerData.gameSGPBalance += playerPayout;
        playerData.totalSgpEarned += playerPayout;

        // Clear and reseed all lottery pools
        _reseedPools(reseedTotal);

        emit JackpotWon(player, playerPayout, reseedTotal);
        emit LotteryPlayed(player, TileType.JACKPOT, true, 0, playerPayout, 0);
        emit TileEffectProcessed(
            player,
            playerData.position,
            TileType.JACKPOT,
            int256(playerPayout),
            block.timestamp
        );

        return int256(playerPayout);
    }

    /**
     * @notice Gets total jackpot (sum of ALL lottery tile pools)
     * @dev Jackpot has NO dedicated pool - prize is % of all lottery pools sum
     * @return total Total SGP across all lottery tile pools
     */
    function getTotalJackpot() public view returns (uint256 total) {
        // Sum all lottery tile pools (keyed by position)
        uint256 numPools = lotteryTilePositions.length;
        for (uint256 i = 0; i < numPools; i++) {
            total += lotteryPools[lotteryTilePositions[i]];
        }
        return total;
    }

    /**
     * @notice Reseeds all lottery tile pools after jackpot win
     * @dev Distributes reseed amount equally across all lottery tile pools
     * @param totalReseed Total SGP to distribute across pools
     */
    function _reseedPools(uint256 totalReseed) internal {
        LeaderboardLib.reseedPools(lotteryTilePositions, lotteryPools, totalReseed);
    }

    /**
     * @notice Reconciles SBT Owned SGP to the canonical GameBoard balance and adds the
     *         ranked values to the SBT and the current season.
     * @dev Earned SGP and Dice Purchased remain cumulative and only receive additions.
     *      Callers pass 0 for anything granted dice produced, so it reaches no ranking.
     *      `poolAdd` is the leaderboard USDC of a purchase, credited to the current season.
     */
    function _syncPlayerProgress(
        address player,
        uint256 targetOwnedSgp,
        uint256 earnedAdd,
        uint256 diceAdd,
        uint256 poolAdd
    ) internal {
        if (playerProgressSBT == address(0)) {
            revert InvalidGameConfig();
        }

        (uint256 currentOwnedSgp, , ) = IPlayerProgressSBT(playerProgressSBT).getPlayerMetrics(
            player,
            gameConfig.gameId
        );

        int256 ownedDelta = _ownedSgpDelta(currentOwnedSgp, targetOwnedSgp);
        IPlayerProgressSBT(playerProgressSBT).batchUpdatePlayer(
            player,
            gameConfig.gameId,
            ownedDelta,
            earnedAdd,
            diceAdd
        );

        // A purchase's pool share always comes with its dice, so this sees every share.
        if (earnedAdd | diceAdd != 0) {
            LeaderboardLib.recordSeason(player, earnedAdd, diceAdd, poolAdd);
        }
    }

    function _ownedSgpDelta(
        uint256 currentValue,
        uint256 targetValue
    ) internal pure returns (int256) {
        if (targetValue >= currentValue) {
            uint256 increase = targetValue - currentValue;
            if (increase > uint256(type(int256).max)) {
                revert PlayerProgressValueTooLarge(increase);
            }
            return int256(increase);
        }

        uint256 decrease = currentValue - targetValue;
        if (decrease > uint256(type(int256).max)) {
            revert PlayerProgressValueTooLarge(decrease);
        }
        return -int256(decrease);
    }

    // ========================================================================
    // LEADERBOARD REWARDS (V3; season settlement since V12)
    // ========================================================================

    /**
     * @notice Closes the oldest unsettled season and makes its rewards claimable
     * @dev Permissionless; the keeper sends it right after each UTC month ends. Settles
     *      one season per call, in order, so call again while it keeps succeeding.
     *      Ranks everyone who scored that season on Earned and Dice, half of the pool
     *      each, by rewardTiers (re-normalized if fewer players than tiers); the same
     *      player can win in both. Records stay claimable until the end of the month
     *      after the season. Logic lives in LeaderboardLib.settleSeason.
     * @return season The season settled
     * @return distributed USDC written into claim records
     */
    function settleSeason() external returns (uint256 season, uint256 distributed) {
        return LeaderboardLib.settleSeason();
    }

    /**
     * @notice Ranking data of one season, for display
     * @param season Season id, `year * 12 + (month - 1)` of a UTC date
     * @return seasonPlayers_ Everyone who scored, in the order they first scored
     * @return earned Earned value per player (tokens won by rolls of paid dice)
     * @return dice Dice value per player (dice bought with USDC)
     * @return pool USDC the season would be settled with now; 0 once settled
     */
    function getSeason(
        uint256 season
    )
        external
        view
        returns (
            address[] memory seasonPlayers_,
            uint256[] memory earned,
            uint256[] memory dice,
            uint256 pool
        )
    {
        return LeaderboardLib.seasonView(season);
    }

    /**
     * @notice Claim a specific leaderboard reward by index
     * @dev Transfers USDC for the specified claim record to caller.
     * @param index Index of the claim record in the player's array
     * @return amount Amount of USDC claimed
     */
    function claimLeaderboardReward(uint256 index) external returns (uint256 amount) {
        // Record checks and the claimed flag run in LeaderboardLib (cold path, kept out
        // of this contract's bytecode); it reverts with the errors declared above.
        amount = LeaderboardLib.claimOne(playerClaimRecords[msg.sender], index);
        totalUnclaimedRewards -= amount;

        usdcToken.safeTransfer(msg.sender, amount);

        emit LeaderboardRewardClaimed(msg.sender, amount);
    }

    /**
     * @notice Claim all pending leaderboard rewards at once
     * @dev Iterates through all unclaimed, non-expired records and transfers total USDC.
     * @return totalAmount Total USDC claimed across all records
     */
    function claimAllLeaderboardRewards() external returns (uint256 totalAmount) {
        totalAmount = LeaderboardLib.claimAll(playerClaimRecords[msg.sender]);

        if (totalAmount == 0) {
            revert NoRewardToClaim();
        }

        totalUnclaimedRewards -= totalAmount;
        usdcToken.safeTransfer(msg.sender, totalAmount);

        emit LeaderboardRewardClaimed(msg.sender, totalAmount);
    }

    /**
     * @notice Claim selected expired rewards, including those of exited players, to treasury
     * @dev Admin only. Recipient is the existing platform treasury, never the supplied player.
     * @param player Original reward owner
     * @param indices Claim record indices; duplicates or ineligible records revert the whole call
     * @return amount Total USDC sent to treasury
     */
    function claimExpiredRewards(
        address player,
        uint256[] calldata indices
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 amount) {
        amount = LeaderboardLib.claimExpired(playerClaimRecords[player], indices);
        _transferExpiredRewards(amount, indices.length);
    }

    /**
     * @notice Legacy sweep selector: now admin-only and pays expired rewards to treasury
     * @dev Scans the active roster only. Use claimExpiredRewards for bounded batches and exited players.
     * @return recycledAmount Total USDC sent to treasury; nothing returns to the ranking pool
     */
    function recycleExpiredRewards()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 recycledAmount)
    {
        uint256 recycledFrom;
        (recycledAmount, recycledFrom) = LeaderboardLib.recycleExpired(
            playerAddresses,
            playerClaimRecords
        );

        _transferExpiredRewards(recycledAmount, recycledFrom);
    }

    function _transferExpiredRewards(uint256 amount, uint256 recordCount) private {
        address recipient = treasury;
        if (recipient == address(0)) revert TreasuryNotSet();
        if (recipient == address(this)) revert InvalidGameConfig();
        if (amount == 0) {
            revert NoFeesToWithdraw();
        }

        totalUnclaimedRewards -= amount;
        usdcToken.safeTransfer(recipient, amount);

        emit ExpiredRewardsClaimed(msg.sender, recipient, amount, recordCount);
    }

    /**
     * @notice Update reward tier configuration
     * @dev Only callable by admin. Percentages must sum to BASIS_POINTS (10000).
     * @param _percentages Array of percentages in basis points for each tier
     */
    function setRewardTiers(uint16[] calldata _percentages) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Validation and the rebuild run in LeaderboardLib (cold path, kept out of this
        // contract's bytecode); it reverts with the errors declared above.
        LeaderboardLib.replaceRewardTiers(rewardTiers, _percentages, MAX_REWARD_TIERS);

        emit RewardTiersUpdated(_percentages.length);
    }

    /**
     * @notice Update reward claim period
     * @dev Only callable by admin. Minimum 1 day, maximum 365 days.
     * @param _period New claim period in seconds
     */
    function setRewardClaimPeriod(uint256 _period) external onlyRole(DEFAULT_ADMIN_ROLE) {
        LeaderboardLib.setRewardClaimPeriod(REWARD_CLAIM_PERIOD_SLOT, _period);
    }

    /**
     * @notice Get complete leaderboard reward information
     * @return totalPool Current accumulated leaderboard fees (USDC)
     * @return totalDistributed Total USDC distributed across all distributions
     * @return numDistributions Number of distributions that have occurred
     * @return unclaimed Total unclaimed rewards currently pending
     * @return claimDeadline Current claim deadline timestamp (0 if no active distribution)
     * @return tierCount Number of configured reward tiers
     */
    function getLeaderboardRewardInfo()
        external
        view
        returns (
            uint256 totalPool,
            uint256 totalDistributed,
            uint256 numDistributions,
            uint256 unclaimed,
            uint256 claimDeadline,
            uint256 tierCount
        )
    {
        return (
            leaderboardFeeAccumulated,
            totalLeaderboardDistributed,
            distributionCount,
            totalUnclaimedRewards,
            rewardClaimDeadline,
            rewardTiers.length
        );
    }

    /**
     * @notice Get all reward tier percentages
     * @return percentages Array of tier percentages in basis points
     */
    function getRewardTiers() external view returns (uint16[] memory percentages) {
        percentages = new uint16[](rewardTiers.length);
        for (uint256 i = 0; i < rewardTiers.length; i++) {
            percentages[i] = rewardTiers[i].percentage;
        }
    }

    /**
     * @notice Get claimable reward for a specific player
     * @param player Player address
     * @return amount Claimable USDC amount
     */
    /**
     * @notice Get all claim records for a player
     * @param player Player address
     * @return records Array of all claim records (claimed and unclaimed)
     */
    function getPlayerClaimRecords(
        address player
    ) external view returns (LeaderboardLib.ClaimRecord[] memory) {
        return playerClaimRecords[player];
    }

    /**
     * @notice Get total claimable amount for a player (sum of unclaimed, non-expired records)
     * @param player Player address
     * @return amount Total claimable USDC
     */
    function getClaimableReward(address player) external view returns (uint256 amount) {
        return LeaderboardLib.claimable(playerClaimRecords[player]);
    }

    /**
     * @notice Get distribution history
     * @return records Array of all distribution records
     */
    function getDistributionHistory()
        external
        view
        returns (LeaderboardLib.DistributionRecord[] memory records)
    {
        return distributionHistory;
    }

    // ========================================================================
    // PAUSABILITY
    // ========================================================================

    /**
     * @notice Pauses the contract (emergency mechanism)
     */
    function pause() external onlyRole(GAME_ENGINE_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the contract
     */
    function unpause() external onlyRole(GAME_ENGINE_ROLE) {
        _unpause();
    }
}
