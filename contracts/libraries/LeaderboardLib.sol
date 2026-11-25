// SPDX-License-Identifier: MIT
// ABOUTME: Holds reward distribution, lottery configuration, and pool reseeding helpers.
// ABOUTME: Linked and DELEGATECALLed so this bytecode lives outside SugorokuGameBoard.
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { TransientSlot } from "@openzeppelin/contracts/utils/TransientSlot.sol";
import { StorageSlot } from "@openzeppelin/contracts/utils/StorageSlot.sol";
import { SugorokuGameBoard } from "../SugorokuGameBoard.sol";

/**
 * @title LeaderboardLib
 * @notice Leaderboard reward types plus the season ranking work that scales with player count.
 * @dev The season functions are `external` on purpose: an `internal` library function is
 *      inlined into its caller and would free no GameBoard bytecode at all. They reach the
 *      board's season storage through fixed slots (see SEASONS below), so the board passes
 *      no storage pointers and its call sites stay a few bytes each.
 *
 *      Storage safety: RewardTier and DistributionRecord were moved verbatim out of
 *      SugorokuGameBoard and must keep their slot layout. ClaimRecord is deliberately
 *      repacked for issue #198, which is only safe while no board holds live records:
 *      shrinking the struct changes the array element stride, so every existing entry
 *      would be re-read from the wrong slot. Verified 2026-09-17 — all four BSC mainnet
 *      boards report distributionCount == 0, and both testnet boards holding records
 *      were drained to totalUnclaimedRewards == 0 before this change.
 */
library LeaderboardLib {
    // Same signatures as SugorokuGameBoard's, so reverts and logs decode against its ABI.
    error InvalidAmount();
    error InvalidFeeConfig(uint256 totalRate);
    error TreasuryNotSet();
    error NoFeesToWithdraw();
    event FeeConfigUpdated(
        uint256 dicePrice,
        uint256 platformFeeRate,
        uint256 leaderboardFeeRate,
        uint256 ammPoolFeeRate,
        uint256 goalFeeRate
    );
    event PlatformFeesWithdrawn(address indexed recipient, uint256 amount);
    event OperatorTokensWithdrawn(address indexed recipient, uint256 amount);

    function _word(uint256 slot) private pure returns (StorageSlot.Uint256Slot storage) {
        return StorageSlot.getUint256Slot(bytes32(slot));
    }

    /**
     * @dev Writes dicePrice and the three rates that follow it in consecutive slots,
     *      plus goalFeeRate in its own slot. The four rates must sum to 10000.
     */
    function setFeeConfig(
        uint256 dicePriceSlot,
        uint256 goalFeeSlot,
        uint256 dicePrice,
        uint256 platformFeeRate,
        uint256 leaderboardFeeRate,
        uint256 ammPoolFeeRate,
        uint256 goalFeeRate
    ) external {
        if (dicePrice == 0) revert InvalidAmount();
        uint256 totalRate = platformFeeRate + leaderboardFeeRate + ammPoolFeeRate + goalFeeRate;
        if (totalRate != 10000) revert InvalidFeeConfig(totalRate);
        _word(dicePriceSlot).value = dicePrice;
        _word(dicePriceSlot + 1).value = platformFeeRate;
        _word(dicePriceSlot + 2).value = leaderboardFeeRate;
        _word(dicePriceSlot + 3).value = ammPoolFeeRate;
        _word(goalFeeSlot).value = goalFeeRate;
        emit FeeConfigUpdated(
            dicePrice,
            platformFeeRate,
            leaderboardFeeRate,
            ammPoolFeeRate,
            goalFeeRate
        );
    }

    /**
     * @dev Sends the USDC fees and all but 1 wei of the accrued game tokens to
     *      `recipient`, updating both accruals first. The 1 wei left behind keeps the
     *      accrual slot nonzero, so the next lottery loss pays a nonzero-to-nonzero
     *      write instead of the ~20k zero-to-nonzero one. Reverts when there is
     *      nothing to send, or when `recipient` is the board itself.
     * @return amount USDC sent
     */
    function withdrawOperatorFees(
        uint256 platformFeeSlot,
        uint256 operatorTokenSlot,
        address recipient,
        address usdcToken,
        address gameToken
    ) external returns (uint256 amount) {
        if (recipient == address(0)) revert TreasuryNotSet();
        // Runs by DELEGATECALL, so address(this) is the board.
        if (recipient == address(this)) revert InvalidGameConfig();
        amount = _word(platformFeeSlot).value;
        uint256 accrued = _word(operatorTokenSlot).value;
        uint256 tokens = accrued > 1 ? accrued - 1 : 0;
        if (amount == 0 && tokens == 0) revert NoFeesToWithdraw();
        if (FUNDING_LOCK.asBoolean().tload()) revert FundingReentrancy();
        FUNDING_LOCK.asBoolean().tstore(true);
        _word(platformFeeSlot).value = 0;
        if (amount != 0) {
            IERC20(usdcToken).safeTransfer(recipient, amount);
            emit PlatformFeesWithdrawn(recipient, amount);
        }
        if (tokens != 0) {
            _word(operatorTokenSlot).value = 1;
            IERC20(gameToken).safeTransfer(recipient, tokens);
            emit OperatorTokensWithdrawn(recipient, tokens);
        }
        FUNDING_LOCK.asBoolean().tstore(false);
    }

    error InvalidMove();
    error InvalidGameConfig();

    function _isLotteryTile(SugorokuGameBoard.TileType tileType) private pure returns (bool) {
        return
            tileType == SugorokuGameBoard.TileType.LOTTERY_1 ||
            tileType == SugorokuGameBoard.TileType.LOTTERY_2 ||
            tileType == SugorokuGameBoard.TileType.LOTTERY_3;
    }

    /// @dev Single-tile write; records a new lottery position once, keeping existing ones.
    function configureTile(
        mapping(uint256 => SugorokuGameBoard.TileConfig) storage tiles,
        uint256[] storage lotteryTilePositions,
        uint256 boardType,
        uint256 position,
        SugorokuGameBoard.TileType tileType,
        int16 effectValue
    ) external {
        if (position >= boardType) revert InvalidMove();
        if (position == 0 && _isLotteryTile(tileType)) revert InvalidGameConfig();
        tiles[position] = SugorokuGameBoard.TileConfig({
            tileType: tileType,
            effectValue: effectValue
        });
        if (_isLotteryTile(tileType)) {
            uint256 len = lotteryTilePositions.length;
            for (uint256 i = 0; i < len; i++) {
                if (lotteryTilePositions[i] == position) return;
            }
            lotteryTilePositions.push(position);
        }
    }

    /// @dev Batch write; rebuilds the lottery position list from the supplied tiles.
    function configureTilesBatch(
        mapping(uint256 => SugorokuGameBoard.TileConfig) storage tiles,
        uint256[] storage lotteryTilePositions,
        uint256 boardType,
        uint256[] calldata positions,
        SugorokuGameBoard.TileType[] calldata tileTypes,
        int16[] calldata effectValues
    ) external {
        uint256 length = positions.length;
        if (length != tileTypes.length || length != effectValues.length) {
            revert InvalidGameConfig();
        }
        // Clear existing lottery tile positions before reconfiguring
        while (lotteryTilePositions.length != 0) lotteryTilePositions.pop();
        for (uint256 i = 0; i < length; i++) {
            if (positions[i] >= boardType) revert InvalidMove();
            // Position 0 is the goal; a lottery there would reopen a game-token goal pool.
            if (positions[i] == 0 && _isLotteryTile(tileTypes[i])) revert InvalidGameConfig();
            tiles[positions[i]] = SugorokuGameBoard.TileConfig({
                tileType: tileTypes[i],
                effectValue: effectValues[i]
            });
            // Jackpot tiles have no dedicated pool
            if (_isLotteryTile(tileTypes[i])) lotteryTilePositions.push(positions[i]);
        }
    }

    using SafeERC20 for IERC20;
    using TransientSlot for *;

    /// @dev Read-only force-exit eligibility scan; preserves roster order and grace boundary.
    function getClaimablePlayers(
        address[] storage playerAddresses,
        mapping(address => SugorokuGameBoard.Player) storage players,
        mapping(address => uint256) storage pendingMoveTargetBlocks
    ) external view returns (address[] memory claimable) {
        uint256 count = 0;
        uint256 len = playerAddresses.length;
        for (uint256 i = 0; i < len; i++) {
            SugorokuGameBoard.Player storage p = players[playerAddresses[i]];
            if (
                p.roundCompleted &&
                p.claimDeadline > 0 &&
                block.timestamp >= p.claimDeadline &&
                pendingMoveTargetBlocks[playerAddresses[i]] == 0
            ) {
                count++;
            }
        }
        claimable = new address[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < len; i++) {
            SugorokuGameBoard.Player storage p = players[playerAddresses[i]];
            if (
                p.roundCompleted &&
                p.claimDeadline > 0 &&
                block.timestamp >= p.claimDeadline &&
                pendingMoveTargetBlocks[playerAddresses[i]] == 0
            ) {
                claimable[idx++] = playerAddresses[i];
            }
        }
    }

    // Use the board's existing type so neither public ABI nor persistent layout changes.
    error InvalidLotteryConfig();
    event PoolsReseeded(uint256 totalAmount, uint256 perPoolAmount);

    /// @dev Runs during board initialization through the already-linked library.
    function initializeLotteryConfigs(
        SugorokuGameBoard.LotteryConfig[4] storage lotteryConfigs
    ) external {
        lotteryConfigs[0] = SugorokuGameBoard.LotteryConfig({
            winRate: 8000,
            poolPayoutRate: 5000,
            lossStakeRate: 2000
        });
        lotteryConfigs[1] = SugorokuGameBoard.LotteryConfig({
            winRate: 5000,
            poolPayoutRate: 7500,
            lossStakeRate: 4000
        });
        lotteryConfigs[2] = SugorokuGameBoard.LotteryConfig({
            winRate: 2000,
            poolPayoutRate: 9500,
            lossStakeRate: 5000
        });
        lotteryConfigs[3] = SugorokuGameBoard.LotteryConfig({
            winRate: 500,
            poolPayoutRate: 5000,
            lossStakeRate: 0
        });
    }

    /// @dev Authorization and the public configuration event stay in GameBoard.
    function setLotteryConfigs(
        SugorokuGameBoard.LotteryConfig[4] storage lotteryConfigs,
        uint16[12] calldata flat
    ) external {
        for (uint256 i = 0; i < 12; i++) {
            if (flat[i] > 10000) revert InvalidLotteryConfig();
        }
        for (uint256 t = 0; t < 4; t++) {
            uint256 base = t * 3;
            lotteryConfigs[t] = SugorokuGameBoard.LotteryConfig({
                winRate: flat[base],
                poolPayoutRate: flat[base + 1],
                lossStakeRate: flat[base + 2]
            });
        }
    }

    /// @dev Delegatecall keeps the original board event emitter and last-pool remainder.
    function reseedPools(
        uint256[] storage positions,
        mapping(uint256 => uint256) storage pools,
        uint256 totalReseed
    ) external {
        uint256 numPools = positions.length;
        if (numPools == 0) return;
        uint256 perPoolAmount = totalReseed / numPools;
        uint256 distributed = 0;
        for (uint256 i = 0; i < numPools; i++) {
            uint256 position = positions[i];
            if (i == numPools - 1) {
                pools[position] = totalReseed - distributed;
            } else {
                pools[position] = perPoolAmount;
                distributed += perPoolAmount;
            }
        }
        emit PoolsReseeded(totalReseed, perPoolAmount);
    }

    // Namespaced transient lock adds no persistent storage to existing boards.
    bytes32 private constant FUNDING_LOCK = keccak256("sugoroku.leaderboard.funding.lock");

    error FundingReentrancy();
    error FundingBalanceMismatch();

    /// @dev Runs via delegatecall; caller authorization remains in GameBoard.
    function _receiveFunding(address tokenAddress, uint256 amount) private {
        if (FUNDING_LOCK.asBoolean().tload()) revert FundingReentrancy();
        FUNDING_LOCK.asBoolean().tstore(true);
        IERC20 token = IERC20(tokenAddress);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) - balanceBefore != amount)
            revert FundingBalanceMismatch();
        FUNDING_LOCK.asBoolean().tstore(false);
    }

    error InvalidClaimPeriod(uint256 period);
    event RewardClaimPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /// @dev Claim period bounds are 1 to 365 days.
    function setRewardClaimPeriod(uint256 periodSlot, uint256 period) external {
        if (period < 1 days || period > 365 days) revert InvalidClaimPeriod(period);
        uint256 oldPeriod = _word(periodSlot).value;
        _word(periodSlot).value = period;
        emit RewardClaimPeriodUpdated(oldPeriod, period);
    }

    /// @dev `treasury` occupies a whole slot by itself, so the full word is replaced.
    function setTreasury(uint256 treasurySlot, address newTreasury) external {
        if (newTreasury == address(0)) revert InvalidGameConfig();
        StorageSlot.AddressSlot storage slot = StorageSlot.getAddressSlot(bytes32(treasurySlot));
        address oldTreasury = slot.value;
        slot.value = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    event LeaderboardFunded(address indexed funder, uint256 usdcAmount);
    event GoalTreasuryFunded(address indexed funder, uint256 usdcAmount);

    /**
     * @dev Pulls exactly `amount` USDC from the caller and adds it to the budget held
     *      in `budgetSlot`: the leaderboard pool, or the goal treasury when `goal` is set.
     *      Leaderboard funding belongs to the season it arrives in, like a purchase's share.
     */
    function fundBudget(uint256 budgetSlot, address usdcToken, uint256 amount, bool goal) external {
        if (amount == 0) revert InvalidAmount();
        _receiveFunding(usdcToken, amount);
        _word(budgetSlot).value += amount;
        if (goal) {
            emit GoalTreasuryFunded(msg.sender, amount);
        } else {
            _seasonPool()[seasonOf(block.timestamp)] += amount;
            emit LeaderboardFunded(msg.sender, amount);
        }
    }

    /// @dev Width of the Earned field inside a packed season stats slot.
    uint256 private constant METRIC_MASK = (1 << 96) - 1;

    /// @dev A single reward exceeded the width ClaimRecord.amount was packed into.
    error ClaimAmountTooLarge(uint256 amount);

    // Same signatures as SugorokuGameBoard's, so a revert from the claim functions below
    // decodes against the GameBoard ABI exactly as it did when the GameBoard raised it.
    error InvalidClaimIndex(uint256 index, uint256 length);
    error AlreadyClaimed(uint256 index);
    error RewardClaimExpired(uint256 deadline, uint256 currentTime);
    error ClaimDeadlineNotExpired(uint256 deadline, uint256 currentTime);
    /// @dev Pre-repack record misread at the new stride; its amount has no accounting behind it
    error LegacyClaimRecord(uint256 index);
    error InvalidRewardTiers(uint256 totalPercentage);
    error TooManyRewardTiers(uint256 count, uint256 max);

    /// @dev Tier percentages must sum to this many basis points.
    uint256 private constant BASIS_POINTS = 10000;

    /**
     * @notice Reward tier configuration for leaderboard distribution
     * @dev Percentage in basis points (e.g., 2500 = 25%)
     */
    struct RewardTier {
        uint16 percentage; // Basis points (sum of all tiers must equal 10000)
    }

    /**
     * @notice Record of a single leaderboard reward distribution
     */
    struct DistributionRecord {
        uint256 totalAmount; // Total USDC distributed
        address jackpotWinner; // Jackpot winner before V12; zero for a season settlement
        uint256 timestamp; // When distribution occurred
        uint256 claimDeadline; // Deadline for claiming rewards
    }

    /**
     * @notice Individual claimable reward record for a player
     * @dev Each distribution (a season settlement since V12, a jackpot before) creates
     *      separate records per winning player.
     *      Packed into one slot (96 + 32 + 40 + 40 + 8 = 216 bits). A single jackpot
     *      move writes up to 30 of these, and at five slots each they dominated the
     *      distribution's gas — see issue #198.
     *
     *      The external ABI keeps its wire format: every static struct field still
     *      occupies one 32-byte word, so callers holding the older all-uint256 ABI
     *      decode the same values without being regenerated.
     */
    struct ClaimRecord {
        uint96 amount; // USDC claimable; max 7.9e28, far above any pool
        uint32 distributionId; // Which distribution this came from
        uint40 timestamp; // When this record was created
        uint40 claimDeadline; // Inclusive player deadline; admin recovery only after this
        bool claimed; // Whether this record has been claimed
    }

    // ========================================================================
    // SEASONS (V12)
    // ========================================================================
    //
    // A season is one UTC calendar month, from the 1st at 00:00:00 to the last day at
    // 23:59:59. Its id is `year * 12 + (month - 1)`, so it is never zero.
    //
    // Two rankings, each paid half of the season's pool:
    //   - Earned: game tokens won by rolls of paid dice.
    //   - Dice: dice bought with USDC.
    // Granted dice (DiceNFT redemptions, summon rewards included, and operator restores) count in
    // neither, and neither do the rolls that use them. Everyone who scored during the
    // season is ranked, including players who have since exited.
    //
    // The board's season storage is reached through fixed slots, pinned by
    // test/GoalPayoutStorage.test.ts, so the board's call sites pass no storage pointers.

    uint256 private constant LEADERBOARD_POOL_SLOT = 27;
    uint256 private constant REWARD_TIERS_SLOT = 33;
    uint256 private constant CLAIM_RECORDS_SLOT = 34;
    uint256 private constant DISTRIBUTION_HISTORY_SLOT = 35;
    uint256 private constant TOTAL_DISTRIBUTED_SLOT = 36;
    uint256 private constant DISTRIBUTION_COUNT_SLOT = 37;
    uint256 private constant TOTAL_UNCLAIMED_SLOT = 38;
    uint256 private constant REWARD_CLAIM_DEADLINE_SLOT = 39;
    uint256 private constant SEASON_STATS_SLOT = 47;
    uint256 private constant SEASON_PLAYERS_SLOT = 48;
    uint256 private constant SEASON_POOL_SLOT = 49;
    uint256 private constant NEXT_SEASON_SLOT = 50;

    /// @dev Same signature as SugorokuGameBoard's, so the log decodes against its ABI.
    event LeaderboardRewardsDistributed(
        uint256 indexed distributionId,
        uint256 totalAmount,
        address indexed jackpotWinner,
        address[] winners,
        uint256[] amounts,
        uint256 claimDeadline
    );

    /**
     * @dev A season was closed. `distributionId` is 0 when nothing was paid (no player
     *      scored, an empty pool, or a settlement after the claim deadline); the pool then
     *      stays in leaderboardFeeAccumulated and goes to the next season.
     */
    event SeasonSettled(
        uint256 indexed season,
        uint256 indexed distributionId,
        uint256 pool,
        uint256 distributed,
        uint256 claimDeadline
    );

    /// @dev `season` is 0 (no season has a score yet) or is not over yet.
    error SeasonNotOver(uint256 season);

    /// @dev A season value outgrew its packed field.
    error SeasonValueTooLarge(uint256 value);

    /// @dev Reward tiers cannot change while a season is being ranked over several calls.
    error SeasonSettlementInProgress(uint256 processed);

    /// @dev A long roster was partly ranked; call settleSeason again to continue.
    event SeasonSettlementProgress(uint256 indexed season, uint256 processed, uint256 total);

    /// @dev Players ranked per settleSeason call. 5.6k-9k gas each by ranking order, so a full chunk
    ///      plus the payout stays well inside BEP-652's 2^24 per-transaction cap.
    uint256 private constant SETTLE_CHUNK = 500;

    /// @dev A shortlist saved between the calls of a chunked settlement. Tiers are capped
    ///      at 10 (MAX_REWARD_TIERS in the board), so ten keys each always fit.
    struct StoredList {
        uint256[10] front;
        uint256[10] tail;
        uint256 frontLen;
        uint256 tailLen;
        uint256 minPos;
        uint256 eligible;
    }

    /// @dev Chunked settlement state. `cursor` is the next roster index to rank, 0 when
    ///      no settlement is under way; the season is always nextSeasonToSettle.
    struct SettleProgress {
        uint256 cursor;
        StoredList earned;
        StoredList dice;
    }

    /// @dev keccak256("sugoroku.season.settle.progress") - 1, away from the board's layout.
    bytes32 private constant SETTLE_PROGRESS_SLOT = 0xcca49accf8ec18175c4b9f31df35f71d07507dd20f28167b863b8ce8a995eb80;

    function _progress() private pure returns (SettleProgress storage p) {
        bytes32 slot = SETTLE_PROGRESS_SLOT;
        assembly ("memory-safe") {
            p.slot := slot
        }
    }

    function _seasonStats()
        private
        pure
        returns (mapping(uint256 => mapping(address => uint256)) storage m)
    {
        assembly ("memory-safe") {
            m.slot := SEASON_STATS_SLOT
        }
    }

    function _seasonPlayers() private pure returns (mapping(uint256 => address[]) storage m) {
        assembly ("memory-safe") {
            m.slot := SEASON_PLAYERS_SLOT
        }
    }

    function _seasonPool() private pure returns (mapping(uint256 => uint256) storage m) {
        assembly ("memory-safe") {
            m.slot := SEASON_POOL_SLOT
        }
    }

    function _rewardTiers() private pure returns (RewardTier[] storage a) {
        assembly ("memory-safe") {
            a.slot := REWARD_TIERS_SLOT
        }
    }

    function _claimRecords() private pure returns (mapping(address => ClaimRecord[]) storage m) {
        assembly ("memory-safe") {
            m.slot := CLAIM_RECORDS_SLOT
        }
    }

    function _distributionHistory() private pure returns (DistributionRecord[] storage a) {
        assembly ("memory-safe") {
            a.slot := DISTRIBUTION_HISTORY_SLOT
        }
    }

    /**
     * @notice Season id of a timestamp: `year * 12 + (month - 1)` of its UTC date
     * @dev civil_from_days (H. Hinnant), unsigned since every timestamp is after 1970.
     */
    function seasonOf(uint256 timestamp) internal pure returns (uint256) {
        uint256 z = timestamp / 1 days + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        // mp counts months from March: 0..9 are March..December, 10..11 January..February.
        uint256 year = yoe + era * 400 + (mp >= 10 ? 1 : 0);
        uint256 monthIndex = mp < 10 ? mp + 2 : mp - 10;
        return year * 12 + monthIndex;
    }

    /**
     * @notice Timestamp of 00:00:00 UTC on the first day of `season`
     * @dev days_from_civil (H. Hinnant) for day 1. Valid for seasons from March 1970 on.
     */
    function seasonStart(uint256 season) internal pure returns (uint256) {
        uint256 month = (season % 12) + 1;
        uint256 year = season / 12 - (month <= 2 ? 1 : 0);
        uint256 era = year / 400;
        uint256 yoe = year - era * 400;
        uint256 doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return (era * 146097 + doe - 719468) * 1 days;
    }

    /**
     * @notice Adds to the current season's values of `player` and to its pool
     * @dev Called only with `earnedAdd` or `diceAdd` nonzero (a purchase's pool share
     *      comes with its dice). The first value of a player in a season appends them to that season's
     *      roster, and the first one after the upgrade marks the season settlement starts
     *      from. Earned is 96 bits wide (bits 0..95), Dice 32 (bits 96..127).
     * @param player Player whose values grow
     * @param earnedAdd Tokens won by a roll of a paid die
     * @param diceAdd Dice bought with USDC
     * @param poolAdd Leaderboard USDC from that purchase
     */
    function recordSeason(
        address player,
        uint256 earnedAdd,
        uint256 diceAdd,
        uint256 poolAdd
    ) external {
        uint256 season = seasonOf(block.timestamp);
        if (poolAdd != 0) _seasonPool()[season] += poolAdd;

        mapping(address => uint256) storage stats = _seasonStats()[season];
        uint256 packed = stats[player];
        if (packed == 0) {
            _seasonPlayers()[season].push(player);
            StorageSlot.Uint256Slot storage next = _word(NEXT_SEASON_SLOT);
            if (next.value == 0) next.value = season;
        }
        uint256 earned = (packed & METRIC_MASK) + earnedAdd;
        uint256 dice = (packed >> 96) + diceAdd;
        if (earned > METRIC_MASK) revert SeasonValueTooLarge(earned);
        if (dice > type(uint32).max) revert SeasonValueTooLarge(dice);
        stats[player] = earned | (dice << 96);
    }

    /**
     * @notice Closes the oldest unsettled season and writes its claim records
     * @dev Permissionless: the keeper sends it right after each month ends, and anyone
     *      may. Seasons settle one at a time, in order. A roster longer than
     *      SETTLE_CHUNK is ranked over several calls (SeasonSettlementProgress), so no
     *      season can outgrow one transaction's gas and block the ones after it.
     *      The pool is the undistributed leaderboard USDC minus what later seasons
     *      added, so it includes leftovers of earlier seasons and the pool a board held
     *      before V12. Records can be claimed until the end of the month after the
     *      season; a settlement finished later than that pays nothing and leaves the
     *      pool to the next season.
     * @return season The season this call worked on
     * @return distributed USDC written into claim records; 0 while still ranking
     */
    function settleSeason() external returns (uint256 season, uint256 distributed) {
        StorageSlot.Uint256Slot storage next = _word(NEXT_SEASON_SLOT);
        season = next.value;
        uint256 current = seasonOf(block.timestamp);
        if (season == 0 || season >= current) revert SeasonNotOver(season);

        uint256 numTiers = _rewardTiers().length;
        address[] storage roster = _seasonPlayers()[season];
        uint256 n = roster.length;
        SettleProgress storage progress = _progress();
        uint256 start = progress.cursor;
        Shortlist memory earnedList = _newShortlist(numTiers, n);
        Shortlist memory diceList = _newShortlist(numTiers, n);
        if (start != 0) {
            _loadList(progress.earned, earnedList);
            _loadList(progress.dice, diceList);
        }
        uint256 end = n - start > SETTLE_CHUNK ? start + SETTLE_CHUNK : n;
        mapping(address => uint256) storage stats = _seasonStats()[season];
        // Two SLOADs per player (address, packed values) and one offer per ranking,
        // which a full shortlist settles with a single comparison.
        for (uint256 i = start; i < end; i++) {
            uint256 packed = stats[roster[i]];
            _offer(earnedList, i, packed & METRIC_MASK);
            _offer(diceList, i, packed >> 96);
        }
        if (end < n) {
            _saveList(progress.earned, earnedList);
            _saveList(progress.dice, diceList);
            progress.cursor = end;
            emit SeasonSettlementProgress(season, end, n);
            return (season, 0);
        }
        progress.cursor = 0;
        next.value = season + 1;

        uint256 pool = _seasonPoolAt(season, current);
        uint256 deadline = seasonStart(season + 2) - 1;
        uint256 distId;
        if (pool != 0 && block.timestamp <= deadline) {
            distId = _word(DISTRIBUTION_COUNT_SLOT).value + 1;
            distributed = _payout(roster, earnedList, diceList, pool, distId, deadline);
        }
        if (distributed == 0) {
            distId = 0;
        } else {
            _word(LEADERBOARD_POOL_SLOT).value -= distributed;
            _word(TOTAL_DISTRIBUTED_SLOT).value += distributed;
            _word(TOTAL_UNCLAIMED_SLOT).value += distributed;
            _word(DISTRIBUTION_COUNT_SLOT).value = distId;
            _word(REWARD_CLAIM_DEADLINE_SLOT).value = deadline;
            _distributionHistory().push(
                DistributionRecord({
                    totalAmount: distributed,
                    jackpotWinner: address(0),
                    timestamp: block.timestamp,
                    claimDeadline: deadline
                })
            );
            emit LeaderboardRewardsDistributed(
                distId,
                distributed,
                address(0),
                new address[](0),
                new uint256[](0),
                deadline
            );
        }
        emit SeasonSettled(season, distId, pool, distributed, deadline);
    }

    /**
     * @notice Everything the ranking display needs for one season
     * @param season Season id (`year * 12 + month - 1`)
     * @return players Everyone who scored, in the order they first scored (ties go to the earlier)
     * @return earned Earned value per player
     * @return dice Dice value per player
     * @return pool USDC the season would be settled with now; 0 once settled
     */
    function seasonView(
        uint256 season
    )
        external
        view
        returns (
            address[] memory players,
            uint256[] memory earned,
            uint256[] memory dice,
            uint256 pool
        )
    {
        address[] storage roster = _seasonPlayers()[season];
        mapping(address => uint256) storage stats = _seasonStats()[season];
        uint256 n = roster.length;
        players = new address[](n);
        earned = new uint256[](n);
        dice = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            address who = roster[i];
            uint256 packed = stats[who];
            players[i] = who;
            earned[i] = packed & METRIC_MASK;
            dice[i] = packed >> 96;
        }

        uint256 next = _word(NEXT_SEASON_SLOT).value;
        uint256 current = seasonOf(block.timestamp);
        if (season > current || (next != 0 && season < next)) {
            pool = 0;
        } else if (next == 0 || season == next) {
            pool = _seasonPoolAt(season, current);
        } else {
            // Earlier seasons are still open; they take the carried-over balance first.
            pool = _seasonPool()[season];
        }
    }

    /// @dev Undistributed leaderboard USDC minus what seasons after `season` added.
    function _seasonPoolAt(uint256 season, uint256 current) private view returns (uint256 pool) {
        pool = _word(LEADERBOARD_POOL_SLOT).value;
        mapping(uint256 => uint256) storage added = _seasonPool();
        for (uint256 t = season + 1; t <= current; t++) {
            uint256 later = added[t];
            pool = pool > later ? pool - later : 0;
        }
    }

    /// @dev Writes the claim records of both rankings, half of the pool each.
    function _payout(
        address[] storage roster,
        Shortlist memory earnedList,
        Shortlist memory diceList,
        uint256 pool,
        uint256 distId,
        uint256 deadline
    ) private returns (uint256 distributed) {
        RewardTier[] storage tiers = _rewardTiers();
        uint256 numTiers = tiers.length;
        if (numTiers == 0) return 0;
        uint256 earnedPool = pool / 2;
        mapping(address => ClaimRecord[]) storage records = _claimRecords();
        distributed = _payMetric(
            tiers,
            records,
            roster,
            _rankShortlist(earnedList, numTiers),
            earnedPool,
            distId,
            deadline
        );
        distributed += _payMetric(
            tiers,
            records,
            roster,
            _rankShortlist(diceList, numTiers),
            pool - earnedPool,
            distId,
            deadline
        );
    }

    /// @dev Restores a shortlist saved by _saveList into one sized by _newShortlist.
    function _loadList(StoredList storage stored, Shortlist memory list) private view {
        uint256 frontLen = stored.frontLen;
        uint256 tailLen = stored.tailLen;
        for (uint256 i = 0; i < frontLen; i++) list.front[i] = stored.front[i];
        for (uint256 i = 0; i < tailLen; i++) list.tail[i] = stored.tail[i];
        list.frontLen = frontLen;
        list.tailLen = tailLen;
        list.minPos = stored.minPos;
        list.eligible = stored.eligible;
    }

    function _saveList(StoredList storage stored, Shortlist memory list) private {
        uint256 frontLen = list.frontLen;
        uint256 tailLen = list.tailLen;
        for (uint256 i = 0; i < frontLen; i++) stored.front[i] = list.front[i];
        for (uint256 i = 0; i < tailLen; i++) stored.tail[i] = list.tail[i];
        stored.frontLen = frontLen;
        stored.tailLen = tailLen;
        stored.minPos = list.minPos;
        stored.eligible = list.eligible;
    }

    /**
     * @notice Ranks one metric's values exactly as the season settlement does
     * @dev Exposed for tests that compare the ranking against the original full
     *      selection sort; `settleSeason` runs the same offer/rank steps inline.
     * @param values Metric value per roster index
     * @param numTiers Number of reward tiers
     * @return winners Roster indexes of the winners, best first
     */
    function rankTop(
        uint256[] memory values,
        uint256 numTiers
    ) internal pure returns (uint256[] memory winners) {
        Shortlist memory list = _newShortlist(numTiers, values.length);
        for (uint256 i = 0; i < values.length; i++) {
            _offer(list, i, values[i]);
        }
        return _rankShortlist(list, numTiers);
    }

    /**
     * @dev Everything one metric needs to reproduce a full selection sort over the roster.
     *
     *      The original ranking ran K = min(numTiers, eligible) rounds of selection sort
     *      over every player: each round takes the largest remaining value, ties going to
     *      the lowest *current* array position, then swaps it into place. Those swaps move
     *      only the elements sitting in positions below K, so from position numTiers on
     *      every element stays put until it is picked. Two consequences make a shortlist
     *      exact:
     *
     *        - Positions below numTiers (`front`) must all be kept, since the swaps
     *          reshuffle them.
     *        - Past that, only the best numTiers elements by (value desc, index asc) can
     *          ever be picked: each of them beats every other stationary element, and at
     *          most numTiers rounds run. `tail` holds that set, unordered.
     *
     *      Running the same selection sort over front ++ tail (tail sorted by index)
     *      preserves every relative position the comparisons depend on, so it picks the
     *      same winners in the same order.
     *
     *      Entries are keys `value << 32 | (KEY_INDEX_MASK - index)`: a larger key is a
     *      larger value, or the same value at a lower index, so one comparison orders them.
     */
    struct Shortlist {
        uint256[] front;
        uint256 frontLen;
        uint256[] tail;
        uint256 tailLen;
        uint256 minPos; // position of the smallest tail key, valid once the tail is full
        uint256 eligible;
    }

    /// @dev Low bits of a shortlist key, holding the complemented roster index.
    uint256 private constant KEY_INDEX_MASK = type(uint32).max;

    function _newShortlist(
        uint256 numTiers,
        uint256 numPlayers
    ) private pure returns (Shortlist memory list) {
        uint256 frontCap = numTiers < numPlayers ? numTiers : numPlayers;
        uint256 rest = numPlayers - frontCap;
        list.front = new uint256[](frontCap);
        list.tail = new uint256[](numTiers < rest ? numTiers : rest);
    }

    /// @dev Offers roster index `i` with value `v`; indexes must arrive in increasing order.
    function _offer(Shortlist memory list, uint256 i, uint256 v) private pure {
        if (v > 0) {
            list.eligible++;
        }
        uint256 key = (v << 32) | (KEY_INDEX_MASK - i);
        if (list.frontLen < list.front.length) {
            list.front[list.frontLen++] = key;
            return;
        }

        uint256[] memory tail = list.tail;
        uint256 cap = tail.length;
        if (list.tailLen < cap) {
            tail[list.tailLen++] = key;
            if (list.tailLen == cap) {
                list.minPos = _minPos(tail);
            }
            return;
        }
        if (cap == 0 || key < tail[list.minPos]) {
            return;
        }
        tail[list.minPos] = key;
        list.minPos = _minPos(tail);
    }

    function _minPos(uint256[] memory keys) private pure returns (uint256 pos) {
        uint256 lowest = keys[0];
        for (uint256 t = 1; t < keys.length; t++) {
            if (keys[t] < lowest) {
                lowest = keys[t];
                pos = t;
            }
        }
    }

    /// @dev Runs the original selection sort over the shortlist; returns roster indexes.
    function _rankShortlist(
        Shortlist memory list,
        uint256 numTiers
    ) private pure returns (uint256[] memory winners) {
        if (list.eligible == 0) {
            return new uint256[](0);
        }
        // Determine actual number of winners: min(tiers, eligible players)
        uint256 winnerCount = numTiers < list.eligible ? numTiers : list.eligible;

        // Candidates in roster order: the front as it stands, then the tail by index,
        // which for keys means descending key order among equal-value entries — so sort
        // by the index bits alone.
        uint256 frontLen = list.frontLen;
        uint256 n = frontLen + list.tailLen;
        uint256[] memory keys = new uint256[](n);
        for (uint256 i = 0; i < frontLen; i++) {
            keys[i] = list.front[i];
        }
        for (uint256 t = 0; t < list.tailLen; t++) {
            uint256 key = list.tail[t];
            uint256 pos = frontLen + t;
            // Larger index bits mean a lower roster index, which goes first.
            while (pos > frontLen && (keys[pos - 1] & KEY_INDEX_MASK) < (key & KEY_INDEX_MASK)) {
                keys[pos] = keys[pos - 1];
                pos--;
            }
            keys[pos] = key;
        }

        // The original partial selection sort, unchanged, over the candidates' values.
        uint256[] memory val = new uint256[](n);
        uint256[] memory indices = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            val[i] = keys[i] >> 32;
            indices[i] = i;
        }
        for (uint256 k = 0; k < winnerCount; k++) {
            uint256 maxIdx = k;
            for (uint256 j = k + 1; j < n; j++) {
                if (val[indices[j]] > val[indices[maxIdx]]) {
                    maxIdx = j;
                }
            }
            if (maxIdx != k) {
                uint256 temp = indices[k];
                indices[k] = indices[maxIdx];
                indices[maxIdx] = temp;
            }
        }

        winners = new uint256[](winnerCount);
        for (uint256 k = 0; k < winnerCount; k++) {
            winners[k] = KEY_INDEX_MASK - (keys[indices[k]] & KEY_INDEX_MASK);
        }
    }

    /**
     * @notice Writes one metric's claim records for its ranked winners
     * @param winners Roster indexes, best first; empty when no player has a value
     * @param metricPool Total USDC to distribute for this metric
     * @return distributed Total USDC distributed for this metric
     */
    function _payMetric(
        RewardTier[] storage rewardTiers,
        mapping(address => ClaimRecord[]) storage playerClaimRecords,
        address[] storage playerAddresses,
        uint256[] memory winners,
        uint256 metricPool,
        uint256 distId,
        uint256 deadline
    ) private returns (uint256 distributed) {
        uint256 winnerCount = winners.length;

        // Calculate re-normalized percentages if fewer winners than tiers
        uint256 totalPercentage = 0;
        for (uint256 k = 0; k < winnerCount; k++) {
            totalPercentage += rewardTiers[k].percentage;
        }

        // Distribute rewards to top K players
        for (uint256 k = 0; k < winnerCount; k++) {
            address winner = playerAddresses[winners[k]];
            uint256 amount;
            if (k == winnerCount - 1) {
                // Last winner gets remainder to avoid dust
                amount = metricPool - distributed;
            } else {
                // Re-normalize: (tierPercentage / totalPercentage) * metricPool
                amount = (metricPool * rewardTiers[k].percentage) / totalPercentage;
            }
            // Only `amount` is checked: it is the money field and is bounded by a
            // caller-supplied pool. `distId` would need 4.3e9 jackpots on one board to
            // overflow uint32, and uint40 timestamps run to the year 36812.
            if (amount > type(uint96).max) {
                revert ClaimAmountTooLarge(amount);
            }
            playerClaimRecords[winner].push(
                ClaimRecord({
                    amount: uint96(amount),
                    distributionId: uint32(distId),
                    timestamp: uint40(block.timestamp),
                    claimDeadline: uint40(deadline),
                    claimed: false
                })
            );
            distributed += amount;
        }
    }

    // ========================================================================
    // CLAIM AND RECYCLE (cold paths, moved out of SugorokuGameBoard for size)
    // ========================================================================
    //
    // These keep only the record bookkeeping. The GameBoard still does the accounting,
    // the transfer, its own "nothing to claim/recycle" revert and the event, so its ABI,
    // events and errors are unchanged.

    /**
     * @notice Marks one record claimed and returns its amount
     * @dev Reverts if the index is out of range, already claimed or past its deadline.
     * @param records The caller's claim records
     * @param index Index of the record to claim
     * @return amount USDC the record held
     */
    function claimOne(
        ClaimRecord[] storage records,
        uint256 index
    ) external returns (uint256 amount) {
        if (index >= records.length) {
            revert InvalidClaimIndex(index, records.length);
        }

        ClaimRecord storage record = records[index];
        if (record.claimed) {
            revert AlreadyClaimed(index);
        }
        if (block.timestamp > record.claimDeadline) {
            revert RewardClaimExpired(record.claimDeadline, block.timestamp);
        }

        record.claimed = true;
        amount = record.amount;
    }

    /**
     * @notice Marks every unclaimed, unexpired record claimed
     * @param records The caller's claim records
     * @return totalAmount Sum of the amounts marked claimed; 0 if none
     */
    function claimAll(ClaimRecord[] storage records) external returns (uint256 totalAmount) {
        uint256 len = records.length;

        for (uint256 i = 0; i < len; i++) {
            ClaimRecord storage record = records[i];
            if (!record.claimed && block.timestamp <= record.claimDeadline) {
                record.claimed = true;
                totalAmount += record.amount;
            }
        }
    }

    /**
     * @notice Consume a bounded selection of expired records, independent of the active roster
     */
    function claimExpired(
        ClaimRecord[] storage records,
        uint256[] calldata indices
    ) external returns (uint256 amount) {
        for (uint256 i = 0; i < indices.length; i++) {
            uint256 index = indices[i];
            if (index >= records.length) revert InvalidClaimIndex(index, records.length);
            ClaimRecord storage record = records[index];
            if (record.claimed) revert AlreadyClaimed(index);
            // Every distributed record has a nonzero deadline; zero means pre-repack bytes.
            if (record.claimDeadline == 0) revert LegacyClaimRecord(index);
            if (block.timestamp <= record.claimDeadline) {
                revert ClaimDeadlineNotExpired(record.claimDeadline, block.timestamp);
            }
            record.claimed = true;
            amount += record.amount;
        }
    }

    /**
     * @notice Marks every expired, unclaimed record of the roster consumed
     * @param playerAddresses Roster, read straight from the caller's storage
     * @param playerClaimRecords Per-player claim records
     * @return recycledAmount Sum of the amounts consumed; 0 if none
     * @return recycledFrom Number of records consumed
     */
    function recycleExpired(
        address[] storage playerAddresses,
        mapping(address => ClaimRecord[]) storage playerClaimRecords
    ) external returns (uint256 recycledAmount, uint256 recycledFrom) {
        uint256 numPlayers = playerAddresses.length;

        for (uint256 i = 0; i < numPlayers; i++) {
            ClaimRecord[] storage records = playerClaimRecords[playerAddresses[i]];
            for (uint256 j = 0; j < records.length; j++) {
                ClaimRecord storage record = records[j];
                // Zero deadline = pre-repack bytes, not a real liability: leave it alone.
                if (
                    !record.claimed &&
                    record.claimDeadline != 0 &&
                    block.timestamp > record.claimDeadline
                ) {
                    record.claimed = true; // Mark as consumed
                    recycledAmount += record.amount;
                    recycledFrom++;
                }
            }
        }
    }

    /**
     * @notice Sum of a player's unclaimed, unexpired records
     * @param records The player's claim records
     * @return amount Total claimable USDC
     */
    function claimable(ClaimRecord[] storage records) external view returns (uint256 amount) {
        for (uint256 i = 0; i < records.length; i++) {
            if (!records[i].claimed && block.timestamp <= records[i].claimDeadline) {
                amount += records[i].amount;
            }
        }
    }

    // ========================================================================
    // REWARD TIER SETUP (cold paths, moved out of SugorokuGameBoard for size)
    // ========================================================================

    /**
     * @notice Appends the default top-10 tiers
     * @dev Exponential decay curve: top 3 receive 56%, remaining 7 receive 44%.
     * @param rewardTiers The caller's (empty) tier array
     */
    function pushDefaultRewardTiers(RewardTier[] storage rewardTiers) external {
        rewardTiers.push(RewardTier({ percentage: 2500 })); // 1st: 25%
        rewardTiers.push(RewardTier({ percentage: 1800 })); // 2nd: 18%
        rewardTiers.push(RewardTier({ percentage: 1300 })); // 3rd: 13%
        rewardTiers.push(RewardTier({ percentage: 1000 })); // 4th: 10%
        rewardTiers.push(RewardTier({ percentage: 800 })); // 5th: 8%
        rewardTiers.push(RewardTier({ percentage: 700 })); // 6th: 7%
        rewardTiers.push(RewardTier({ percentage: 600 })); // 7th: 6%
        rewardTiers.push(RewardTier({ percentage: 500 })); // 8th: 5%
        rewardTiers.push(RewardTier({ percentage: 450 })); // 9th: 4.5%
        rewardTiers.push(RewardTier({ percentage: 350 })); // 10th: 3.5%
    }

    /**
     * @notice Validates new tier percentages and replaces the caller's tiers with them
     * @param rewardTiers The caller's tier array
     * @param percentages New percentages in basis points; must sum to 10000
     * @param maxTiers Most tiers allowed
     */
    function replaceRewardTiers(
        RewardTier[] storage rewardTiers,
        uint16[] calldata percentages,
        uint256 maxTiers
    ) external {
        if (percentages.length > maxTiers) {
            revert TooManyRewardTiers(percentages.length, maxTiers);
        }
        uint256 processed = _progress().cursor;
        if (processed != 0) revert SeasonSettlementInProgress(processed);

        uint256 total = 0;
        for (uint256 i = 0; i < percentages.length; i++) {
            total += percentages[i];
        }
        if (total != BASIS_POINTS) {
            revert InvalidRewardTiers(total);
        }

        // Clear and rebuild
        while (rewardTiers.length > 0) {
            rewardTiers.pop();
        }
        for (uint256 i = 0; i < percentages.length; i++) {
            rewardTiers.push(RewardTier({ percentage: percentages[i] }));
        }
    }
}
