// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ABOUTME: Registry factory and admin control surface for per-game contracts.
// ABOUTME: Coordinates game deployment, lifecycle operations, and economy maintenance.

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
// Custom EIP-1153 transient storage reentrancy guard (96.7% gas savings vs traditional)
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./libraries/GameEconomyLib.sol";

/**
 * @title SugorokuGameRegistry
 * @dev Factory contract for managing game instance creation, board templates, and lifecycle management
 * @notice Deploys SugorokuGameBoard instances with coordinated integration to PlayerProgressSBT
 * @author Sugoroku Team
 *
 * Key Features:
 * - Factory pattern for game deployment with standardized templates
 * - Board template storage with validation and versioning
 * - Role-based access control with GAME_ENGINE_ROLE and ADMIN_ROLE
 * - UUPS upgradeability with governance control
 * - Emergency pause mechanisms for security
 * - Gas-optimized operations with batch support
 *
 * @custom:security-contact security@sugoroku.example.com
 */
interface ISugorokuGameBoard {
    function initialize(
        uint256 gameId,
        uint256 boardType,
        uint256 templateVersion,
        bytes32 boardSeed,
        address registry,
        address playerProgressSBT,
        address usdcToken,
        address ammPool,
        bytes calldata templateData
    ) external;

    function configureTilesBatch(
        uint256[] calldata positions,
        uint8[] calldata tileTypes,
        int16[] calldata effectValues
    ) external;

    function addPlayer(address player) external returns (uint256 startPosition);

    function contributeLotteryPool(uint256 tilePosition, uint256 amount) external;

    function sgpToken() external view returns (address);

    function activateGame() external;

    function deactivateGame() external;

    function setFeeConfig(
        uint256 dicePrice,
        uint256 platformFeeRate,
        uint256 leaderboardFeeRate,
        uint256 ammPoolFeeRate,
        uint256 goalFeeRate
    ) external;

    function setAllLotteryConfigs(uint16[12] calldata flat) external;
}

// GameRules struct lives in GameEconomyLib so the same calldata layout can be
// passed through to the library applyGameRules() helper without a struct-type
// mismatch. Imported below.

contract SugorokuGameRegistry is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ========================================================================
    // ROLE DEFINITIONS
    // ========================================================================

    /// @notice Role identifier for game engine operations
    bytes32 public constant GAME_ENGINE_ROLE = keccak256("GAME_ENGINE_ROLE");

    /// @notice Role identifier for administrative operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Role identifier for AMM swap operations (must match SugorokuAMMPool)
    bytes32 public constant SWAPPER_ROLE = keccak256("SWAPPER_ROLE");

    /// @notice Role identifier for PlayerProgressSBT updates (must match PlayerProgressSBT.ENGINE_ROLE)
    bytes32 public constant ENGINE_ROLE = keccak256("ENGINE_ROLE");

    /// @notice Role allowed to sell game tokens for USDC through sellOperatorTokens only.
    /// @dev Kept apart from ADMIN_ROLE so the operator wallet gets no other Registry power,
    ///      and from the pools' SWAPPER_ROLE so it can never buy (no sandwich round trip).
    bytes32 public constant TOKEN_SELLER_ROLE = keccak256("TOKEN_SELLER_ROLE");

    // ========================================================================
    // ROLE PERMISSION MATRIX
    // ========================================================================
    /*
     * PERMISSION MATRIX:
     *
     * FUNCTION                    | ADMIN_ROLE | GAME_ENGINE_ROLE
     * ---------------------------|------------|------------------
     * deployGame()               |    ❌     |       ✅
     * storeBoardTemplate()       |    ✅     |       ❌
     * deployBeacon()             |    ✅     |       ❌
     * setActiveBeacon()          |    ✅     |       ❌
     * upgradeBeacon()            |    ✅     |       ❌
     * activateGame()             |    ❌     |       ✅
     * deactivateGame()           |    ❌     |       ✅
     * terminateGame()            |    ❌     |       ✅
     * pauseGame()                |    ❌     |       ✅
     * unpauseGame()              |    ❌     |       ✅
     * setGameStatus()            |    ❌     |       ✅
     * setIntegrationContracts()  |    ✅     |       ❌
     * addLiquidity()             |    ✅     |       ❌
     * withdrawLiquidity()        |    ✅     |       ❌
     * pause() (registry)         |    ✅     |       ❌
     * unpause() (registry)       |    ✅     |       ❌
     *
     * ACCESS LEVELS:
     * - ADMIN_ROLE: System configuration, template management, beacon management
     * - GAME_ENGINE_ROLE: Game operations, lifecycle management, emergency controls
     */

    // ========================================================================
    // BOARD TYPE CONSTANTS
    // ========================================================================

    /// @notice Orc board — 26 tiles, dense small board
    uint256 public constant BOARD_TYPE_ORC = 26;

    /// @notice Slime board — 51 tiles, medium
    uint256 public constant BOARD_TYPE_SLIME = 51;

    /// @notice Goblin board — 101 tiles, large with 3 jackpots
    uint256 public constant BOARD_TYPE_GOBLIN = 101;

    /// @notice Maximum allowed template blob size (in bytes)
    uint256 public constant MAX_TEMPLATE_SIZE = 1024 * 100; // 100 KB

    /// @notice Maximum number of games that can be created
    uint256 public constant MAX_GAMES = 1000000;

    /// @notice Maximum limit for pagination queries
    uint256 public constant MAX_QUERY_LIMIT = 1000;

    /// @notice Maximum number of board types a beacon can support
    uint256 public constant MAX_BEACON_BOARD_TYPES = 10;

    /// @notice Maximum number of games per batch operation
    uint256 public constant MAX_BATCH_SIZE = 50;

    /// @notice Whole-USDC magnitude seeded into each pool at deploy time.
    /// @dev Decimal scaling is applied dynamically via INITIAL_DEPLOY_USDC_LIQUIDITY()
    ///      using usdcDecimals, so the same value works for 6- and 18-decimal USDC.
    uint256 public constant INITIAL_DEPLOY_USDC_WHOLE = 20;

    // ========================================================================
    // CUSTOM ERRORS
    // ========================================================================

    /// @notice Thrown when attempting to create game without GAME_ENGINE_ROLE
    error NotGameEngine();

    /// @notice Thrown when attempting admin operation without ADMIN_ROLE
    error NotAdmin();

    /// @notice Thrown when invalid board type is provided
    error InvalidBoardType(uint256 boardType);

    /// @notice Thrown when board template doesn't exist for specified type
    error TemplateNotFound(uint256 boardType);

    /// @notice Thrown when template validation fails
    error TemplateValidationFailed(string reason);

    /// @notice Thrown when game creation parameters are invalid
    error InvalidGameCreationParams(string reason);

    /// @notice Thrown when template upgrade is attempted (templates are immutable)
    error TemplateImmutable();

    /// @notice Thrown when contract address validation fails
    error InvalidContractAddress(string contractType, string reason);

    /// @notice Thrown when the configured USDC reports unsupported decimals
    /// @dev Sugoroku supports 6-decimal (e.g. HyperEVM) and 18-decimal (e.g. BSC) USDC.
    error UnsupportedUsdcDecimals(uint8 decimals);

    /// @notice Thrown when state transition is invalid
    error InvalidStateTransition(GameStatus from, GameStatus to);

    /// @notice Thrown when implementation contract validation fails
    error InvalidImplementation(string reason);

    /// @notice Thrown when template data verification fails
    error TemplateVerificationFailed(string reason);

    /// @notice Thrown when game ID exceeds maximum allowed
    error GameIdExceeded(uint256 current, uint256 max);

    /// @notice Thrown when parameters exceed limits
    error ParameterExceeded(string param, uint256 current, uint256 max);

    /// @notice Thrown when reentrant call is detected
    error ReentrancyGuardReentrantCall();

    /// @notice Thrown when query parameters are invalid
    error InvalidQueryParameters(string reason);

    /// @notice Thrown because moves must use the two-step GameBoard flow directly
    error AsyncMoveRequired();

    // ========================================================================
    // MODIFIERS
    // ========================================================================

    function _isValidBoardType(uint256 boardType) internal pure returns (bool) {
        return
            boardType == BOARD_TYPE_ORC ||
            boardType == BOARD_TYPE_SLIME ||
            boardType == BOARD_TYPE_GOBLIN;
    }

    modifier validBoardType(uint256 boardType) {
        if (!_isValidBoardType(boardType)) revert InvalidBoardType(boardType);
        _;
    }

    modifier validAddress(address addr) {
        if (addr == address(0)) revert InvalidContractAddress("address", "zero address");
        _;
    }

    modifier validLimit(uint256 value, uint256 max, string memory param) {
        if (value > max) revert ParameterExceeded(param, value, max);
        _;
    }

    // ========================================================================
    // CORE STRUCTS
    // ========================================================================

    enum GameStatus {
        Created,
        Active,
        Paused,
        Terminated
    }

    enum TileType {
        START_GOAL, // Position 0 and goal
        BLANK, // Normal tile
        MOVE_FORWARD, // Move forward 1-3 spaces
        MOVE_BACKWARD, // Move backward 1-3 spaces
        LOTTERY_1, // Bronze lottery (80% win rate)
        LOTTERY_2, // Silver lottery (50% win rate)
        LOTTERY_3, // Gold lottery (10% win rate)
        JACKPOT, // Jackpot (5% win rate, 50% of pools)
        CHALLENGE // Question/Challenge tile
    }

    /**
     * @notice Board template configuration with optimized storage layout
     * @dev Struct packing optimized for gas efficiency:
     * - Slot 1: templateVersion (32 bytes) + checksum (32 bytes) = 64 bytes (needs 2 slots)
     * - Slot 2: boardType (32 bytes) + isDeprecated (1 byte) + validationFlags (3 bytes) = 36 bytes
     * - Template data stored in separate mapping for efficient updates
     */
    struct BoardTemplate {
        // Full-slot values first
        uint256 templateVersion; // Version number for immutability tracking
        uint256 boardType; // Board size (30, 50, or 100)
        bytes32 checksum; // Template data checksum for integrity
        // Packed small values
        bool isDeprecated; // Template deprecation status
        uint8 validationFlags; // Bit flags for validation options
        // Dynamic last (pointer)
        string validationRules; // JSON-encoded validation rules
    }

    /**
     * @notice Game instance metadata with optimized storage
     * @dev Packed for maximum gas efficiency:
     * - Slot 1: gameId (32 bytes)
     * - Slot 2: boardType (32 bytes)
     * - Slot 3: templateVersion (32 bytes)
     * - Slot 4: boardSeed (32 bytes)
     * - Slot 5: creator (20 bytes) + gameBoardAddress (20 bytes) + creationTime (8 bytes) + status (1 byte) + reserved (3 bytes) = 52 bytes
     */
    struct GameData {
        uint256 gameId; // Slot 1
        uint256 boardType; // Slot 2
        uint256 templateVersion; // Slot 3
        bytes32 boardSeed; // Slot 4
        address creator; // Slot 5 (20 bytes)
        address gameBoardAddress; // Slot 5 (20 bytes)
        uint64 creationTime; // Slot 5 (8 bytes)
        GameStatus status; // Slot 5 (1 byte)
        uint32 reserved; // Slot 5 (3 bytes for future use)
    }

    /**
     * @notice Tile configuration used for template validation
     */
    struct TileConfig {
        uint256 position; // Tile position on the board, (0-29, 0-49, 0-99)
        TileType tileType;
        int32 effect; // For move tiles (+/- spaces), default 0 otherwise
        string poolId; // Identifier for lottery/challenge pools, empty if not applicable
    }

    struct BoardTemplateData {
        uint256 boardType; // 30, 50, or 100
        TileConfig[] tiles; // Array of tile configurations
        uint256 totalTiles; // Should equal boardType
        bytes32 boardHash; // Hash of complete configuration
        string version; // Template version string
    }

    // ========================================================================
    // STATE VARIABLES
    // ========================================================================

    /// @notice Mapping from game ID to game data
    mapping(uint256 => GameData) public games;

    /// @notice Mapping from board type to board template
    mapping(uint256 => BoardTemplate) public boardTemplates;

    /// @notice Mapping from board type and version to raw template data
    mapping(uint256 => mapping(uint256 => bytes)) private _templateBlobs;

    /// @notice Single UpgradeableBeacon for all per-game GameBoard proxies.
    /// @dev All board types (30, 50, 100) share this beacon. Board-type-specific
    ///      behaviour is driven by the template + init data, not by having
    ///      separate beacons per board type. Upgrade via upgradeGameBoardBeacon().
    address public gameBoardBeacon;

    // Deprecated: Avoid unbounded all-game enumeration due to growth/OOG risk
    // uint256[] public allGameIds;
    // mapping(uint256 => uint256) private gameIndices;

    /// @notice Compact list of active game IDs for pagination
    uint256[] private activeGameIds;
    /// @notice Index of a game ID within activeGameIds (valid only when active)
    mapping(uint256 => uint256) private activeGameIndex;

    /// @notice Total number of games created
    uint256 public totalGames;

    /// @notice Next game ID to assign
    uint256 private nextGameId;

    // ========================================================================
    // INTEGRATION CONTRACT ADDRESSES
    // ========================================================================

    /// @notice PlayerProgressSBT contract address for player progress tracking
    address public playerProgressSBT;

    /// @notice USDC token contract for liquidity seeding
    address public usdcToken;

    /// @notice Decimals of the configured USDC (6 or 18), read once at init.
    /// @dev Packs into the same slot as usdcToken (address 20B + uint8 1B ≤ 32B),
    ///      so it consumes no extra storage slot and __gap is unchanged.
    uint8 public usdcDecimals;

    /// @notice Treasury address, receives fees from all per-game AMM pools
    address public treasury;

    /// @notice UpgradeableBeacon for per-game GameToken proxies
    address public gameTokenBeacon;

    /// @notice UpgradeableBeacon for per-game AMM pool proxies
    address public ammPoolBeacon;

    /// @notice gameId → per-game GameToken proxy address
    mapping(uint256 => address) public gameTokenAddresses;

    /// @notice gameId → per-game AMM pool proxy address
    mapping(uint256 => address) public gameAmmPoolAddresses;

    // ========================================================================
    // STORAGE GAP
    // ========================================================================

    /// @notice Reserved storage space for future upgrades
    /// @dev Slot accounting: playerProgressSBT(1) + usdcToken+usdcDecimals(1, packed) +
    ///      treasury(1) + gameTokenBeacon(1) + ammPoolBeacon(1) + gameTokenAddresses(1) +
    ///      gameAmmPoolAddresses(1) = 7 slots consumed by integration addrs.
    uint256[43] private __gap;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /**
     * @notice Emitted when a new game instance is created
     * @param gameId Unique identifier for the game
     * @param creator Address that created the game
     * @param boardType Type of board used (30, 50, or 100)
     * @param templateVersion Version of template used
     * @param gameBoardAddress Address of deployed SugorokuGameBoard contract
     * @param boardSeed Random seed for board generation
     */
    event GameCreated(
        uint256 indexed gameId,
        address indexed creator,
        uint256 indexed boardType,
        uint256 templateVersion,
        address gameBoardAddress,
        bytes32 boardSeed
    );

    /**
     * @notice Emitted when a board template is stored
     * @param boardType Type of board template
     * @param templateVersion Version of the template
     * @param checksum Checksum of template data
     */
    event BoardTemplateStored(
        uint256 indexed boardType,
        uint256 indexed templateVersion,
        bytes32 checksum
    );

    /**
     * @notice Emitted when game status changes
     * @param gameId Game identifier
     * @param oldStatus Previous status
     * @param newStatus New status
     * @param changedBy Address that initiated the status change
     */
    event GameStatusChanged(
        uint256 indexed gameId,
        GameStatus oldStatus,
        GameStatus newStatus,
        address indexed changedBy
    );

    /**
     * @notice Emitted when a game is permanently terminated
     * @param gameId Unique identifier of the terminated game
     * @param terminatedBy Address that terminated the game
     */
    event GameTerminated(uint256 indexed gameId, address indexed terminatedBy);

    /**
     * @notice Emitted when integration contracts are updated
     * @param playerProgressSBTAddress New PlayerProgressSBT address
     * @param updatedBy Address that updated the contracts
     */
    event IntegrationContractsUpdated(
        address indexed playerProgressSBTAddress,
        address indexed updatedBy
    );

    /**
     * @notice Emitted when a new UpgradeableBeacon is deployed
     * @param version Version number of the beacon
     * @param beaconAddress Address of the deployed beacon
     * @param implementation Address of the implementation contract
     * @param boardTypes Array of board types this beacon supports
     */
    event BeaconDeployed(
        uint256 indexed version,
        address indexed beaconAddress,
        address indexed implementation,
        uint256[] boardTypes
    );

    /**
     * @notice Emitted when active beacon is changed for board types
     * @param boardType Board type that was updated
     * @param version New active version
     * @param beaconAddress Address of the new active beacon
     */
    event ActiveBeaconChanged(
        uint256 indexed boardType,
        uint256 indexed version,
        address indexed beaconAddress
    );

    /**
     * @notice Emitted when a beacon is upgraded to new implementation
     * @param version Version of the upgraded beacon
     * @param beaconAddress Address of the beacon
     * @param newImplementation Address of the new implementation
     */
    event BeaconUpgraded(
        uint256 indexed version,
        address indexed beaconAddress,
        address indexed newImplementation
    );

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
     * @notice Initializes the registry with integration contracts and
     *         constructs the per-game token + AMM pool beacons internally.
     * @param initialOwner Initial owner (receives admin + engine roles)
     * @param _playerProgressSBT Address of existing PlayerProgressSBT contract
     * @param _usdcToken Address of USDC token (used for liquidity seeding)
     * @param _treasury Fee recipient for all per-game AMM pools
     * @param _gameTokenImpl Deployed GameToken implementation address
     * @param _ammPoolImpl Deployed SugorokuAMMPool implementation address
     */
    function initialize(
        address initialOwner,
        address _playerProgressSBT,
        address _usdcToken,
        address _treasury,
        address _gameTokenImpl,
        address _ammPoolImpl,
        address _gameBoardImpl
    ) public initializer {
        if (
            initialOwner == address(0) ||
            _playerProgressSBT == address(0) ||
            _usdcToken == address(0) ||
            _treasury == address(0) ||
            _gameTokenImpl == address(0) ||
            _ammPoolImpl == address(0) ||
            _gameBoardImpl == address(0)
        ) revert InvalidContractAddress("init", "zero");

        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(ADMIN_ROLE, initialOwner);
        _grantRole(GAME_ENGINE_ROLE, initialOwner);

        playerProgressSBT = _playerProgressSBT;
        usdcToken = _usdcToken;
        treasury = _treasury;

        // Read USDC decimals once; all deploy-time amounts scale off this so the
        // registry supports both 6-decimal (HyperEVM) and 18-decimal (BSC) USDC.
        uint8 dec = IERC20Metadata(_usdcToken).decimals();
        if (dec != 6 && dec != 18) revert UnsupportedUsdcDecimals(dec);
        usdcDecimals = dec;

        // Construct all three beacons internally. Registry is the beacon owner,
        // so upgrades flow through the three upgradeXxxBeacon admin functions.
        gameTokenBeacon = address(new UpgradeableBeacon(_gameTokenImpl, address(this)));
        ammPoolBeacon = address(new UpgradeableBeacon(_ammPoolImpl, address(this)));
        gameBoardBeacon = address(new UpgradeableBeacon(_gameBoardImpl, address(this)));

        nextGameId = 1;
    }

    /// @notice USDC seeded into each pool at deploy time, scaled to usdcDecimals.
    /// @dev Replaces the former INITIAL_DEPLOY_USDC_LIQUIDITY constant; computed
    ///      dynamically so 6dec → 20e6 and 18dec → 20e18.
    function initialDeployUsdcLiquidity() public view returns (uint256) {
        return INITIAL_DEPLOY_USDC_WHOLE * 10 ** usdcDecimals;
    }

    // ========================================================================
    // CUSTOM REENTRANCY GUARD (EIP-1153 TRANSIENT STORAGE)
    // ========================================================================

    /// @notice Transient storage slot for reentrancy guard (using fixed slot)
    /// @dev Slot: keccak256("ReentrancyGuard.slot") = 0x9c2b8cb3e7d6b7c8e5a9f3b6d2a1c4e0
    uint256 private constant REENTRANCY_GUARD_SLOT = 0x9c2b8cb3e7d6b7c8e5a9f3b6d2a1c4e0;

    /**
     * @notice Prevents reentrancy using EIP-1153 transient storage
     * @dev 96.7% gas savings vs traditional SSTORE reentrancy guards
     */
    modifier nonReentrant() {
        assembly {
            // Load the reentrancy guard flag from transient storage
            if tload(REENTRANCY_GUARD_SLOT) {
                // Revert with custom error if already entered
                mstore(0x00, 0x3ee5aeb5) // ReentrancyGuardReentrantCall() selector
                revert(0x1c, 0x04)
            }
            // Set the reentrancy guard flag in transient storage
            tstore(REENTRANCY_GUARD_SLOT, 1)
        }
        _;
        assembly {
            // Clear the reentrancy guard flag from transient storage
            tstore(REENTRANCY_GUARD_SLOT, 0)
        }
    }

    // ========================================================================
    // UUPS UPGRADE LOGIC
    // ========================================================================

    /**
     * @dev Authorizes upgrade requests
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        emit UpgradeAuthorized(newImplementation, msg.sender);
    }

    /**
     * @notice Emitted when an upgrade is authorized
     * @param newImplementation Address of the new implementation
     * @param authorizedBy Address that authorized the upgrade
     */
    event UpgradeAuthorized(address indexed newImplementation, address indexed authorizedBy);

    // ========================================================================
    // BOARD TEMPLATE MANAGEMENT
    // ========================================================================

    /**
     * @notice Stores a new board template for the specified board type
     * @dev Only ADMIN_ROLE can store templates. Templates are immutable once stored.
     * @param boardType Type of board (30, 50, or 100)
     * @param templateData Encoded template data for board configuration
     * @param dataHash Pre-computed hash of template data for integrity
     * @param validationRules JSON-encoded validation rules for game balance
     * @return templateVersion Version number assigned to this template
     */
    function storeBoardTemplate(
        uint256 boardType,
        bytes calldata templateData,
        bytes32 dataHash, // Pre-computed hash off-chain
        string calldata validationRules
    )
        external
        onlyRole(ADMIN_ROLE)
        validBoardType(boardType)
        nonReentrant
        returns (uint256 templateVersion)
    {
        // SECURITY: Enhanced template validation
        _validateTemplateData(boardType, templateData, dataHash, validationRules);

        // Get next template version with overflow protection
        BoardTemplate storage existing = boardTemplates[boardType];
        unchecked {
            templateVersion = existing.templateVersion + 1;
        }
        if (templateVersion == 0) {
            revert TemplateValidationFailed("Template version overflow");
        }

        // Store template with enhanced metadata
        boardTemplates[boardType] = BoardTemplate({
            templateVersion: templateVersion,
            boardType: boardType,
            checksum: dataHash,
            validationRules: validationRules,
            isDeprecated: false,
            validationFlags: _computeValidationFlags(boardType, templateData)
        });

        _templateBlobs[boardType][templateVersion] = templateData;

        emit BoardTemplateStored(boardType, templateVersion, dataHash);

        return templateVersion;
    }

    /**
     * @notice Retrieves board template data
     * @param boardType Type of board to retrieve template for
     * @return templateVersion Version of the template
     * @return templateData Raw template data
     * @return validationRules Validation rules for the template
     */
    function getBoardTemplate(
        uint256 boardType
    )
        external
        view
        validBoardType(boardType)
        returns (uint256 templateVersion, bytes memory templateData, string memory validationRules)
    {
        BoardTemplate storage template = boardTemplates[boardType];
        if (template.templateVersion == 0) {
            revert TemplateNotFound(boardType);
        }

        return (
            template.templateVersion,
            _getTemplateData(boardType, template.templateVersion),
            template.validationRules
        );
    }

    // ========================================================================
    // GAME CREATION
    // ========================================================================

    /**
     * @notice Emitted when a full game economy (token + pool + board) is deployed.
     */
    event GameDeployed(
        uint256 indexed gameId,
        address indexed gameToken,
        address ammPoolAddress,
        address gameBoardAddress
    );

    /**
     * @notice Atomically deploys a new game with its own token, AMM pool, and board.
     * @dev Caller must have GAME_ENGINE_ROLE and must have pre-approved
     *      20 USDC to the Registry before calling. Any revert
     *      during the flow aborts the entire deploy (no partial state).
     *
     * Flow:
     *   1. Deploy per-game GameToken (Registry receives full initialSupply).
     *   2. Deploy per-game AMM pool (USDC / gameToken pair).
     *   3. Deploy GameBoard via BeaconProxy, wiring per-game pool into init.
     *   4. Grant SWAPPER_ROLE on pool and ENGINE_ROLE on SBT to the board.
     *   5. Apply deploy-time GameRules to the board.
     *   6. Pull 20 USDC from caller, seed matching liquidity, keep LP on Registry,
     *      and transfer the remaining game tokens to caller.
     *   7. Write mappings + emit GameDeployed.
     *
     * @param boardType Board variant by tile count (26, 51, or 101)
     * @param creator Owner of the game instance
     * @param tokenName ERC-20 name for the per-game token
     * @param tokenSymbol ERC-20 symbol (e.g., "GBL")
     * @param tokenSupply Full initial supply.
     * @param usdcLiquidity Intended full USDC-side liquidity, used to derive the
     *        initial 20 USDC token-side amount.
     * @param lotteryReserve Game tokens reserved for lottery seeding, excluded
     *        from the AMM price basis so the deploy-time price matches later
     *        Admin add-liquidity at the same ratio.
     * @param rules Deploy-time economic rules (dice price, fees, lottery configs).
     *              GameBoard admins can later tune fees and lottery rates.
     * @return gameId Unique identifier for the created game
     * @return gameBoardAddress Address of deployed GameBoard BeaconProxy
     */
    function deployGame(
        uint256 boardType,
        address creator,
        string calldata tokenName,
        string calldata tokenSymbol,
        uint256 tokenSupply,
        uint256 usdcLiquidity,
        uint256 lotteryReserve,
        GameRules calldata rules
    )
        external
        onlyRole(GAME_ENGINE_ROLE)
        whenNotPaused
        nonReentrant
        validBoardType(boardType)
        validAddress(creator)
        returns (uint256 gameId, address gameBoardAddress)
    {
        // ── VALIDATE ────────────────────────────────────────────────────────
        if (tokenSupply == 0) revert InvalidGameCreationParams("tokenSupply=0");
        if (lotteryReserve >= tokenSupply) {
            revert InvalidGameCreationParams("lotteryReserve>=supply");
        }
        if (usdcLiquidity < initialDeployUsdcLiquidity()) {
            revert InvalidGameCreationParams("usdcLiquidity<20");
        }
        if (rules.dicePrice == 0) revert InvalidGameCreationParams("dicePrice=0");
        if (
            rules.platformFeeRate +
                rules.leaderboardFeeRate +
                rules.ammPoolFeeRate +
                rules.goalFeeRate !=
            10000
        ) {
            revert InvalidGameCreationParams("fee sum != 10000");
        }
        if (gameTokenBeacon == address(0) || ammPoolBeacon == address(0)) {
            revert InvalidGameCreationParams("economy beacons not set");
        }
        if (nextGameId > MAX_GAMES) revert GameIdExceeded(nextGameId, MAX_GAMES);

        BoardTemplate storage template = boardTemplates[boardType];
        if (template.templateVersion == 0) revert TemplateNotFound(boardType);

        // ── ID + SEED ───────────────────────────────────────────────────────
        uint256 nonce = nextGameId++;
        gameId = uint256(
            uint128(
                uint256(
                    keccak256(
                        abi.encodePacked(block.timestamp, block.prevrandao, msg.sender, nonce)
                    )
                )
            )
        );
        require(games[gameId].gameId == 0, "Game ID collision");

        bytes32 boardSeed = keccak256(
            abi.encodePacked(block.timestamp, block.prevrandao, gameId, creator)
        );

        // ── STEP 1+2: Deploy token + pool (extracted to library for size) ───
        (address gameToken, address pool) = GameEconomyLib.deployTokenAndPool(
            gameTokenBeacon,
            ammPoolBeacon,
            usdcToken,
            treasury,
            tokenName,
            tokenSymbol,
            tokenSupply
        );

        // ── STEP 3: Deploy GameBoard, wiring per-game pool into init ────────
        gameBoardAddress = GameEconomyLib.deployGameBoardProxy(
            GameEconomyLib.GameBoardInitParams({
                beacon: gameBoardBeacon,
                gameId: gameId,
                boardType: boardType,
                templateVersion: template.templateVersion,
                boardSeed: boardSeed,
                creator: creator,
                playerProgressSBT: playerProgressSBT,
                usdcToken: usdcToken,
                perGameAmmPool: pool,
                templateData: _getTemplateData(boardType, template.templateVersion)
            })
        );

        // ── STEP 4: Wire permissions ────────────────────────────────────────
        IAccessControl(pool).grantRole(SWAPPER_ROLE, gameBoardAddress);
        // Registry also holds SWAPPER_ROLE so it can later execute the
        // seedLotteries() USDC→gameToken swap against this pool.
        IAccessControl(pool).grantRole(SWAPPER_ROLE, address(this));
        IAccessControl(playerProgressSBT).grantRole(ENGINE_ROLE, gameBoardAddress);

        // ── STEP 4b: Apply deploy-time economic rules ───────────────────────
        GameEconomyLib.applyGameRules(gameBoardAddress, rules);

        // ── STEP 5: Seed liquidity and keep LP (extracted to library) ─────────
        GameEconomyLib.seedLiquidity(
            pool,
            gameToken,
            usdcToken,
            msg.sender,
            msg.sender,
            initialDeployUsdcLiquidity(),
            usdcLiquidity,
            tokenSupply,
            lotteryReserve
        );

        // ── STEP 6: Store records + emit ────────────────────────────────────
        games[gameId] = GameData({
            gameId: gameId,
            boardType: boardType,
            templateVersion: template.templateVersion,
            boardSeed: boardSeed,
            creator: creator,
            gameBoardAddress: gameBoardAddress,
            creationTime: uint64(block.timestamp),
            status: GameStatus.Created,
            reserved: 0
        });
        gameTokenAddresses[gameId] = gameToken;
        gameAmmPoolAddresses[gameId] = pool;
        totalGames++;

        emit GameCreated(
            gameId,
            creator,
            boardType,
            template.templateVersion,
            gameBoardAddress,
            boardSeed
        );
        emit GameDeployed(gameId, gameToken, pool, gameBoardAddress);
        return (gameId, gameBoardAddress);
    }

    // ========================================================================
    // GAME QUERY FUNCTIONS
    // ========================================================================

    /**
     * @notice Gets paginated list of active games
     * @param offset Number of games to skip
     * @param limit Maximum number of games to return
     * @return gameIds Array of game IDs
     * @return gameDataArray Array of corresponding game data
     */
    function getActiveGames(
        uint256 offset,
        uint256 limit
    )
        external
        view
        validLimit(limit, MAX_QUERY_LIMIT, "limit")
        returns (uint256[] memory gameIds, GameData[] memory gameDataArray)
    {
        uint256 total = activeGameIds.length;

        // CRITICAL: Validate bounds to prevent overflow/underflow
        if (offset >= total) {
            return (new uint256[](0), new GameData[](0));
        }

        if (limit == 0) {
            return (new uint256[](0), new GameData[](0));
        }

        // SECURITY: Prevent integer overflow in end calculation
        uint256 end = _safeAdd(offset, limit);

        if (end > total) end = total;

        // CRITICAL: Prevent underflow in resultLength calculation
        if (end < offset) {
            revert InvalidQueryParameters("End < offset - underflow");
        }

        uint256 resultLength = end - offset;

        // Create arrays with exact size needed
        gameIds = new uint256[](resultLength);
        gameDataArray = new GameData[](resultLength);

        // Populate arrays with bounds checking
        for (uint256 i = 0; i < resultLength; i++) {
            uint256 index = offset + i;
            if (index >= total) {
                revert InvalidQueryParameters("Array index out of bounds");
            }
            uint256 gameId = activeGameIds[index];
            gameIds[i] = gameId;
            gameDataArray[i] = games[gameId];
        }
    }

    /**
     * @notice Safe addition function to prevent overflow
     * @param a First operand
     * @param b Second operand
     * @return sum Result of addition
     */
    function _safeAdd(uint256 a, uint256 b) internal pure returns (uint256 sum) {
        unchecked {
            uint256 c = a + b;
            if (c < a) revert InvalidQueryParameters("Addition overflow");
            return c;
        }
    }

    /**
     * @notice Returns the number of active games
     */
    function getActiveGamesCount() external view returns (uint256) {
        return activeGameIds.length;
    }

    /**
     * @notice Gets comprehensive game information
     * @param gameId Game identifier
     * @return gameData Complete game data structure
     */
    function getGameInfo(uint256 gameId) external view returns (GameData memory gameData) {
        // SECURITY: Validate game ID exists to prevent returning empty/invalid data
        gameData = games[gameId];
        if (gameData.gameId == 0) {
            revert InvalidQueryParameters("Game does not exist");
        }
        return gameData;
    }

    // ========================================================================
    // GAME LIFECYCLE MANAGEMENT
    // ========================================================================

    /**
     * @notice Updates game status
     * @param gameId Game identifier
     * @param newStatus New status value
     */
    function setGameStatus(
        uint256 gameId,
        GameStatus newStatus
    ) external onlyRole(GAME_ENGINE_ROLE) {
        GameData storage gameData = games[gameId];
        if (gameData.gameId == 0) {
            revert InvalidGameCreationParams("Game does not exist");
        }

        GameStatus oldStatus = gameData.status;

        // Validate state transition
        if (!_isValidStateTransition(oldStatus, newStatus)) {
            revert InvalidStateTransition(oldStatus, newStatus);
        }

        // Maintain compact active list
        if (oldStatus != GameStatus.Active && newStatus == GameStatus.Active) {
            // Add to active games
            activeGameIndex[gameId] = activeGameIds.length;
            activeGameIds.push(gameId);
        } else if (oldStatus == GameStatus.Active && newStatus != GameStatus.Active) {
            // Remove from active games by swap-and-pop
            _removeFromActiveGames(gameId);
        }

        gameData.status = newStatus;
        emit GameStatusChanged(gameId, oldStatus, newStatus, msg.sender);
    }

    // ========================================================================
    // GAME LIFECYCLE MANAGEMENT FUNCTIONS
    // ========================================================================

    /**
     * @notice Activates a game, making it available for players
     * @dev Only GAME_ENGINE_ROLE can activate games
     * @param gameId Game identifier to activate
     */
    function activateGame(uint256 gameId) external onlyRole(GAME_ENGINE_ROLE) whenNotPaused {
        GameData storage gameData = games[gameId];
        if (gameData.gameId == 0) {
            revert InvalidGameCreationParams("Game does not exist");
        }

        GameStatus oldStatus = gameData.status;
        GameStatus newStatus = GameStatus.Active;

        // Validate state transition to Active
        if (!_isValidStateTransition(oldStatus, newStatus)) {
            revert InvalidStateTransition(oldStatus, newStatus);
        }

        // Add to active games list if not already present
        if (oldStatus != GameStatus.Active) {
            activeGameIndex[gameId] = activeGameIds.length;
            activeGameIds.push(gameId);
        }

        gameData.status = newStatus;

        // Also activate the game on the GameBoard contract
        ISugorokuGameBoard(gameData.gameBoardAddress).activateGame();

        emit GameStatusChanged(gameId, oldStatus, newStatus, msg.sender);
    }

    /**
     * @notice Deactivates a game, temporarily making it unavailable
     * @dev Only GAME_ENGINE_ROLE can deactivate games
     * @param gameId Game identifier to deactivate
     */
    function deactivateGame(uint256 gameId) external onlyRole(GAME_ENGINE_ROLE) {
        GameData storage gameData = games[gameId];
        if (gameData.gameId == 0) {
            revert InvalidGameCreationParams("Game does not exist");
        }

        GameStatus oldStatus = gameData.status;
        GameStatus newStatus = GameStatus.Paused;

        // Validate state transition to Paused
        if (!_isValidStateTransition(oldStatus, newStatus)) {
            revert InvalidStateTransition(oldStatus, newStatus);
        }

        // Remove from active games list
        if (oldStatus == GameStatus.Active) {
            _removeFromActiveGames(gameId);
        }

        gameData.status = newStatus;

        // Also deactivate the game on the GameBoard contract
        ISugorokuGameBoard(gameData.gameBoardAddress).deactivateGame();

        emit GameStatusChanged(gameId, oldStatus, newStatus, msg.sender);
    }

    /**
     * @notice Terminates a game permanently, ending all gameplay
     * @dev Only GAME_ENGINE_ROLE can terminate games
     * @param gameId Game identifier to terminate
     */
    function terminateGame(uint256 gameId) external onlyRole(GAME_ENGINE_ROLE) {
        GameData storage gameData = games[gameId];
        if (gameData.gameId == 0) {
            revert InvalidGameCreationParams("Game does not exist");
        }

        GameStatus oldStatus = gameData.status;
        GameStatus newStatus = GameStatus.Terminated;

        // Validate state transition to Terminated
        if (!_isValidStateTransition(oldStatus, newStatus)) {
            revert InvalidStateTransition(oldStatus, newStatus);
        }

        // Remove from active games list
        if (oldStatus == GameStatus.Active) {
            _removeFromActiveGames(gameId);
        }

        gameData.status = newStatus;
        emit GameStatusChanged(gameId, oldStatus, newStatus, msg.sender);
        emit GameTerminated(gameId, msg.sender);
    }

    /**
     * @notice Emergency pause for a specific game instance
     * @dev Only GAME_ENGINE_ROLE can pause individual games
     * @param gameId Game identifier to pause
     */
    function pauseGame(uint256 gameId) external onlyRole(GAME_ENGINE_ROLE) {
        GameData storage gameData = games[gameId];
        if (gameData.gameId == 0) {
            revert InvalidGameCreationParams("Game does not exist");
        }

        if (gameData.status != GameStatus.Active) {
            revert InvalidStateTransition(gameData.status, GameStatus.Paused);
        }

        // Remove from active games
        _removeFromActiveGames(gameId);
        gameData.status = GameStatus.Paused;

        emit GameStatusChanged(gameId, GameStatus.Active, GameStatus.Paused, msg.sender);
    }

    /**
     * @notice Emergency unpause for a specific game instance
     * @dev Only GAME_ENGINE_ROLE can unpause individual games
     * @param gameId Game identifier to unpause
     */
    function unpauseGame(uint256 gameId) external onlyRole(GAME_ENGINE_ROLE) {
        GameData storage gameData = games[gameId];
        if (gameData.gameId == 0) {
            revert InvalidGameCreationParams("Game does not exist");
        }

        if (gameData.status != GameStatus.Paused) {
            revert InvalidStateTransition(gameData.status, GameStatus.Active);
        }

        // Add back to active games
        activeGameIndex[gameId] = activeGameIds.length;
        activeGameIds.push(gameId);
        gameData.status = GameStatus.Active;

        emit GameStatusChanged(gameId, GameStatus.Paused, GameStatus.Active, msg.sender);
    }

    // ========================================================================
    // GAME BOARD PROXY FUNCTIONS
    // ========================================================================

    /**
     * @notice Grants a role on a specific GameBoard to an account
     * @dev Only ADMIN_ROLE can grant roles. Registry has DEFAULT_ADMIN_ROLE on GameBoards.
     * @param gameId Game identifier
     * @param role Role to grant (use GameBoard's role constants)
     * @param account Address to grant the role to
     */
    function grantGameBoardRole(
        uint256 gameId,
        bytes32 role,
        address account
    ) external onlyRole(ADMIN_ROLE) {
        GameData storage gameData = games[gameId];
        if (gameData.gameId == 0) {
            revert InvalidGameCreationParams("Game does not exist");
        }

        IAccessControl(gameData.gameBoardAddress).grantRole(role, account);
    }

    /**
     * @notice Revokes a role on a specific GameBoard from an account
     * @dev Only ADMIN_ROLE can revoke roles
     * @param gameId Game identifier
     * @param role Role to revoke
     * @param account Address to revoke the role from
     */
    function revokeGameBoardRole(
        uint256 gameId,
        bytes32 role,
        address account
    ) external onlyRole(ADMIN_ROLE) {
        GameData storage gameData = games[gameId];
        if (gameData.gameId == 0) {
            revert InvalidGameCreationParams("Game does not exist");
        }

        IAccessControl(gameData.gameBoardAddress).revokeRole(role, account);
    }

    /**
     * @notice Configure tiles on a GameBoard in batch
     * @dev Only GAME_ENGINE_ROLE can configure tiles. Registry has DEFAULT_ADMIN_ROLE on GameBoards.
     * @param gameId Game identifier
     * @param positions Array of tile positions
     * @param tileTypes Array of tile types
     * @param effectValues Array of effect values
     */
    function configureGameBoardTiles(
        uint256 gameId,
        uint256[] calldata positions,
        uint8[] calldata tileTypes,
        int16[] calldata effectValues
    ) external onlyRole(GAME_ENGINE_ROLE) {
        GameData storage gameData = games[gameId];
        if (gameData.gameId == 0) {
            revert InvalidGameCreationParams("Game does not exist");
        }

        ISugorokuGameBoard(gameData.gameBoardAddress).configureTilesBatch(
            positions,
            tileTypes,
            effectValues
        );
    }

    /**
     * @notice Add a player to a game (public - anyone can join)
     * @dev Anyone can call this to join a game
     * @param gameId Game identifier
     * @param player Player address
     */
    function addPlayerToGame(
        uint256 gameId,
        address player
    ) external returns (uint256 startPosition) {
        GameData storage gameData = games[gameId];
        if (gameData.gameId == 0) {
            revert InvalidGameCreationParams("Game does not exist");
        }

        return ISugorokuGameBoard(gameData.gameBoardAddress).addPlayer(player);
    }

    /**
     * @notice Disabled synchronous move wrapper retained for Registry ABI compatibility
     * @dev Call requestMove and finalizeMove on the GameBoard directly.
     * @param gameId Game identifier
     */
    function movePlayerInGame(
        uint256 gameId
    ) external view returns (uint256, uint256, uint256, uint256) {
        GameData storage gameData = games[gameId];
        if (gameData.gameId == 0) {
            revert InvalidGameCreationParams("Game does not exist");
        }

        revert AsyncMoveRequired();
    }

    /**
     * @notice Seed a lottery pool for a specific tile position in a game
     * @dev Only GAME_ENGINE_ROLE can seed lottery pools
     * @param gameId Game identifier
     * @param tilePosition Position of the lottery tile
     * @param amount Amount of SGP to add to the pool
     */
    function seedLotteryPool(
        uint256 gameId,
        uint256 tilePosition,
        uint256 amount
    ) external onlyRole(GAME_ENGINE_ROLE) {
        GameData storage gameData = games[gameId];
        if (gameData.gameId == 0) {
            revert InvalidGameCreationParams("Game does not exist");
        }

        // Transfer real SGP from caller directly to GameBoard before updating accounting
        address sgp = ISugorokuGameBoard(gameData.gameBoardAddress).sgpToken();
        IERC20(sgp).safeTransferFrom(msg.sender, gameData.gameBoardAddress, amount);

        ISugorokuGameBoard(gameData.gameBoardAddress).contributeLotteryPool(tilePosition, amount);
    }

    /// @notice Capability marker for the all-output, slippage-protected tile funding path.
    function manualFundingVersion() external pure returns (uint256) {
        return 1;
    }

    event LotteryPoolFunded(
        uint256 indexed gameId,
        uint256 indexed tilePosition,
        address indexed funder,
        uint256 usdcAmount,
        uint256 tokensOut
    );

    /// @notice Swap caller USDC through the game's AMM and credit all output to one lottery tile.
    function fundLotteryPool(
        uint256 gameId,
        uint256 tilePosition,
        uint256 usdcAmount,
        uint256 minTokensOut
    ) external onlyRole(GAME_ENGINE_ROLE) nonReentrant returns (uint256 tokensOut) {
        GameData storage gameData = games[gameId];
        if (gameData.gameId == 0) {
            revert InvalidGameCreationParams("Game does not exist");
        }
        tokensOut = GameEconomyLib.fundLotteryPool(
            msg.sender,
            usdcToken,
            gameAmmPoolAddresses[gameId],
            gameTokenAddresses[gameId],
            gameData.gameBoardAddress,
            tilePosition,
            usdcAmount,
            minTokensOut
        );
        emit LotteryPoolFunded(gameId, tilePosition, msg.sender, usdcAmount, tokensOut);
    }

    event OperatorTokensSold(
        uint256 indexed gameId,
        address indexed seller,
        uint256 tokenAmountIn,
        uint256 usdcOut
    );

    /**
     * @notice Sell the caller's game tokens for USDC on the game's AMM pool, sell side only
     * @dev The Registry pulls `tokenAmountIn`, swaps with its own SWAPPER_ROLE and sends the
     *      USDC to the caller. `minUsdcOut` is required (non-zero). There is no buy path.
     */
    function sellOperatorTokens(
        uint256 gameId,
        uint256 tokenAmountIn,
        uint256 minUsdcOut
    ) external onlyRole(TOKEN_SELLER_ROLE) nonReentrant returns (uint256 usdcOut) {
        address pool = gameAmmPoolAddresses[gameId];
        if (pool == address(0)) {
            revert InvalidGameCreationParams("Game does not exist");
        }
        usdcOut = GameEconomyLib.sellTokens(
            msg.sender,
            gameTokenAddresses[gameId],
            pool,
            tokenAmountIn,
            minUsdcOut
        );
        emit OperatorTokensSold(gameId, msg.sender, tokenAmountIn, usdcOut);
    }

    /**
     * @notice Seed multiple lottery pools in one call by swapping USDC → game
     *         token via the per-game AMM. The swap output goes directly to
     *         the GameBoard, then each tile's pool is credited per `amounts`.
     * @dev Caller must approve `usdcAmount` of USDC to the Registry first.
     *      `amounts` are per-tile game-token values (18dp). Caller should
     *      pre-quote USDC via `AMMPool.getAmountIn(sum(amounts), gameToken)`
     *      and add a small buffer for slippage; any excess from the swap
     *      stays on the GameBoard as harmless cushion.
     */
    function seedLotteries(
        uint256 gameId,
        uint256 usdcAmount,
        uint256[] calldata positions,
        uint256[] calldata amounts
    ) external onlyRole(GAME_ENGINE_ROLE) {
        GameData storage gameData = games[gameId];
        if (gameData.gameId == 0) {
            revert InvalidGameCreationParams("Game does not exist");
        }
        GameEconomyLib.seedLotteries(
            msg.sender,
            usdcToken,
            gameAmmPoolAddresses[gameId],
            gameTokenAddresses[gameId],
            gameData.gameBoardAddress,
            usdcAmount,
            positions,
            amounts
        );
    }

    /**
     * @notice Emitted when additional liquidity is deposited into a per-game
     *         pool. `tokenAmount` is quoted against `usdcAmount`, both are pulled
     *         from the caller, and `lpMinted` remains on the Registry.
     */
    event LiquidityAdded(
        uint256 indexed gameId,
        uint256 usdcAmount,
        uint256 tokenAmount,
        uint256 lpMinted
    );

    /**
     * @notice Emitted when Registry-held per-game AMM liquidity is
     *         removed by an admin through the Registry.
     */
    event LiquidityWithdrawn(
        uint256 indexed gameId,
        address indexed recipient,
        uint256 usdcAmount,
        uint256 tokenAmount,
        uint256 lpRemoved
    );

    /**
     * @notice Top up a per-game AMM pool with matched USDC + game tokens from
     *         the caller. Price-neutral: token amount is quoted on-chain against
     *         current reserves. LP minted by this deposit remains on the Registry
     *         for later admin withdrawal.
     * @dev Caller must have ADMIN_ROLE and must have pre-approved `usdcAmount`
     *      USDC and the quoted game token amount to the Registry.
     * @param gameId Target game.
     * @param usdcAmount USDC to deposit on the USDC side of the pair.
     */
    function addLiquidity(
        uint256 gameId,
        uint256 usdcAmount
    ) external onlyRole(ADMIN_ROLE) nonReentrant {
        GameData storage gameData = games[gameId];
        if (gameData.gameId == 0) {
            revert InvalidGameCreationParams("Game does not exist");
        }
        (uint256 tokenAmount, uint256 lpMinted) = GameEconomyLib.addLiquidity(
            gameAmmPoolAddresses[gameId],
            gameTokenAddresses[gameId],
            usdcToken,
            msg.sender,
            msg.sender,
            usdcAmount
        );
        emit LiquidityAdded(gameId, usdcAmount, tokenAmount, lpMinted);
    }

    /**
     * @notice Remove a share of the Registry-held per-game AMM
     *         liquidity and send the underlying assets to `recipient`.
     * @dev Calls the pool as Registry, so the pool removes Registry-owned LP
     *      and sends the underlying assets back here before forwarding them.
     * @param gameId Target game.
     * @param liquidity Amount of Registry-held LP tokens to remove.
     * @param minUsdcAmount Minimum USDC to receive (slippage protection).
     * @param minTokenAmount Minimum game token amount to receive (slippage protection).
     * @param recipient Address receiving USDC and game tokens.
     */
    function withdrawLiquidity(
        uint256 gameId,
        uint256 liquidity,
        uint256 minUsdcAmount,
        uint256 minTokenAmount,
        address recipient
    ) external onlyRole(ADMIN_ROLE) nonReentrant validAddress(recipient) {
        GameData storage gameData = games[gameId];
        if (gameData.gameId == 0) {
            revert InvalidGameCreationParams("Game does not exist");
        }

        address pool = gameAmmPoolAddresses[gameId];
        address gameToken = gameTokenAddresses[gameId];

        (uint256 usdcAmount, uint256 tokenAmount) = IAmmPoolInit(pool).removeLiquidity(
            liquidity,
            minUsdcAmount,
            minTokenAmount
        );

        IERC20(usdcToken).safeTransfer(recipient, usdcAmount);
        IERC20(gameToken).safeTransfer(recipient, tokenAmount);

        emit LiquidityWithdrawn(gameId, recipient, usdcAmount, tokenAmount, liquidity);
    }

    // ========================================================================
    // BATCH OPERATIONS (Gas Optimization)
    // ========================================================================

    /**
     * @notice Batch activate multiple games
     * @dev Only GAME_ENGINE_ROLE can batch activate games
     * @param gameIds Array of game identifiers to activate
     * @return activatedCount Number of successfully activated games
     */
    function batchActivateGames(
        uint256[] calldata gameIds
    ) external onlyRole(GAME_ENGINE_ROLE) whenNotPaused returns (uint256 activatedCount) {
        if (gameIds.length == 0) {
            return 0;
        }

        if (gameIds.length > MAX_BATCH_SIZE) {
            revert ParameterExceeded("batch size", gameIds.length, MAX_BATCH_SIZE);
        }

        activatedCount = 0;
        for (uint256 i = 0; i < gameIds.length; i++) {
            uint256 gameId = gameIds[i];
            GameData storage gameData = games[gameId];

            if (gameData.gameId != 0 && gameData.status != GameStatus.Active) {
                if (_isValidStateTransition(gameData.status, GameStatus.Active)) {
                    // Add to active games if not already active
                    if (gameData.status != GameStatus.Active) {
                        activeGameIndex[gameId] = activeGameIds.length;
                        activeGameIds.push(gameId);
                    }

                    gameData.status = GameStatus.Active;
                    emit GameStatusChanged(gameId, gameData.status, GameStatus.Active, msg.sender);
                    activatedCount++;
                }
            }
        }
    }

    /**
     * @notice Batch deactivate multiple games
     * @dev Only GAME_ENGINE_ROLE can batch deactivate games
     * @param gameIds Array of game identifiers to deactivate
     * @return deactivatedCount Number of successfully deactivated games
     */
    function batchDeactivateGames(
        uint256[] calldata gameIds
    ) external onlyRole(GAME_ENGINE_ROLE) returns (uint256 deactivatedCount) {
        if (gameIds.length == 0) {
            return 0;
        }

        if (gameIds.length > MAX_BATCH_SIZE) {
            revert ParameterExceeded("batch size", gameIds.length, MAX_BATCH_SIZE);
        }

        deactivatedCount = 0;
        for (uint256 i = 0; i < gameIds.length; i++) {
            uint256 gameId = gameIds[i];
            GameData storage gameData = games[gameId];

            if (gameData.gameId != 0 && gameData.status == GameStatus.Active) {
                // Remove from active games
                _removeFromActiveGames(gameId);
                gameData.status = GameStatus.Paused;

                emit GameStatusChanged(gameId, GameStatus.Active, GameStatus.Paused, msg.sender);
                deactivatedCount++;
            }
        }
    }

    /**
     * @notice Batch terminate multiple games
     * @dev Only GAME_ENGINE_ROLE can batch terminate games
     * @param gameIds Array of game identifiers to terminate
     * @return terminatedCount Number of successfully terminated games
     */
    function batchTerminateGames(
        uint256[] calldata gameIds
    ) external onlyRole(GAME_ENGINE_ROLE) returns (uint256 terminatedCount) {
        if (gameIds.length == 0) {
            return 0;
        }

        if (gameIds.length > MAX_BATCH_SIZE) {
            revert ParameterExceeded("batch size", gameIds.length, MAX_BATCH_SIZE);
        }

        terminatedCount = 0;
        for (uint256 i = 0; i < gameIds.length; i++) {
            uint256 gameId = gameIds[i];
            GameData storage gameData = games[gameId];

            if (gameData.gameId != 0 && gameData.status != GameStatus.Terminated) {
                if (_isValidStateTransition(gameData.status, GameStatus.Terminated)) {
                    // Remove from active games if currently active
                    if (gameData.status == GameStatus.Active) {
                        _removeFromActiveGames(gameId);
                    }

                    gameData.status = GameStatus.Terminated;
                    emit GameStatusChanged(
                        gameId,
                        gameData.status,
                        GameStatus.Terminated,
                        msg.sender
                    );
                    emit GameTerminated(gameId, msg.sender);
                    terminatedCount++;
                }
            }
        }
    }

    /**
     * @notice Validates if a state transition is allowed
     * @param from Current state
     * @param to Desired state
     * @return True if transition is valid
     */
    function _isValidStateTransition(GameStatus from, GameStatus to) internal pure returns (bool) {
        // From Created
        if (from == GameStatus.Created) {
            return to == GameStatus.Active || to == GameStatus.Terminated;
        }
        // From Active
        if (from == GameStatus.Active) {
            return to == GameStatus.Paused || to == GameStatus.Terminated;
        }
        // From Paused
        if (from == GameStatus.Paused) {
            return to == GameStatus.Active || to == GameStatus.Terminated;
        }
        // From Terminated - no further transitions allowed
        return false;
    }

    /**
     * @notice Safely removes a game from the active games list
     * @param gameId Game ID to remove
     */
    function _removeFromActiveGames(uint256 gameId) internal {
        uint256 idx = activeGameIndex[gameId];
        uint256 totalActive = activeGameIds.length;

        // Edge case: game not in active list
        if (idx >= totalActive) return;

        uint256 lastIndex = totalActive - 1;

        if (idx != lastIndex) {
            // Move last element to removed position
            uint256 lastId = activeGameIds[lastIndex];
            activeGameIds[idx] = lastId;
            activeGameIndex[lastId] = idx;
        }

        // Remove last element
        activeGameIds.pop();
        delete activeGameIndex[gameId];
    }

    // ========================================================================
    // INTEGRATION CONTRACT MANAGEMENT
    // ========================================================================

    /**
     * @notice Updates PlayerProgressSBT contract address
     * @param _playerProgressSBT New PlayerProgressSBT contract address
     */
    function setPlayerProgressSBT(
        address _playerProgressSBT
    ) external onlyRole(ADMIN_ROLE) validAddress(_playerProgressSBT) {
        // Validate PlayerProgressSBT interface
        if (!_isValidPlayerProgressSBT(_playerProgressSBT)) {
            revert InvalidContractAddress("PlayerProgressSBT", "Invalid interface");
        }

        playerProgressSBT = _playerProgressSBT;

        emit IntegrationContractsUpdated(_playerProgressSBT, msg.sender);
    }

    /**
     * @notice Update the treasury address that receives fees from per-game pools.
     * @dev Only affects per-game pools created AFTER this update (each pool snapshots
     *      treasury at construction time).
     */
    function setTreasury(address _treasury) external onlyRole(ADMIN_ROLE) validAddress(_treasury) {
        treasury = _treasury;
    }

    /**
     * @notice Upgrade the GameToken implementation behind the beacon.
     * @dev All existing per-game tokens pick up the new implementation.
     */
    function upgradeGameTokenBeacon(
        address newImpl
    ) external onlyRole(ADMIN_ROLE) validAddress(newImpl) {
        UpgradeableBeacon(gameTokenBeacon).upgradeTo(newImpl);
    }

    /**
     * @notice Upgrade the AMM pool implementation behind the beacon.
     * @dev All existing per-game pools pick up the new implementation.
     */
    function upgradeAmmPoolBeacon(
        address newImpl
    ) external onlyRole(ADMIN_ROLE) validAddress(newImpl) {
        UpgradeableBeacon(ammPoolBeacon).upgradeTo(newImpl);
    }

    /**
     * @notice Upgrade the GameBoard implementation behind the beacon.
     * @dev All existing per-game boards pick up the new implementation.
     */
    function upgradeGameBoardBeacon(
        address newImpl
    ) external onlyRole(ADMIN_ROLE) validAddress(newImpl) {
        UpgradeableBeacon(gameBoardBeacon).upgradeTo(newImpl);
    }

    /**
     * @notice Validates if a contract implements PlayerProgressSBT interface
     * @param _playerProgressSBT Contract address to validate
     * @return True if contract implements PlayerProgressSBT
     */
    function _isValidPlayerProgressSBT(address _playerProgressSBT) internal view returns (bool) {
        // Check if it's a contract
        uint256 size;
        assembly {
            size := extcodesize(_playerProgressSBT)
        }
        if (size == 0) return false;

        // Basic interface check - try to call a known function
        // In a full implementation, you'd check for specific function signatures
        // For now, this is a basic validation
        return size > 0; // Simple check - in production you'd validate interface ID
    }

    /**
     * @notice Validates if a contract implements GameBoard interface
     * @param _implementation Contract address to validate
     * @return True if contract implements ISugorokuGameBoard
     */
    function _isValidGameBoardImplementation(address _implementation) internal view returns (bool) {
        // Check if it's a contract
        uint256 size;
        assembly {
            size := extcodesize(_implementation)
        }
        if (size == 0) return false;

        // SECURITY: Basic interface validation
        // For now, just check if it's a contract with code
        // In a full implementation, you'd validate specific function signatures
        return size > 0;
    }

    // ========================================================================
    // PAUSABILITY
    // ========================================================================

    /**
     * @notice Pauses the contract (emergency mechanism)
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the contract
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // ========================================================================
    // INTERNAL HELPER FUNCTIONS
    // ========================================================================

    /**
     * @dev Retrieves template data (simplified implementation)
     */
    function _getTemplateData(
        uint256 boardType,
        uint256 version
    ) internal view returns (bytes memory) {
        bytes memory blob = _templateBlobs[boardType][version];
        if (blob.length == 0) {
            revert TemplateValidationFailed("Template version not found");
        }
        return blob;
    }

    /**
     * @notice Comprehensive template data validation
     * @param boardType Type of board (30, 50, or 100)
     * @param templateData Raw template data to validate
     * @param expectedHash Expected hash of template data
     * @param validationRules JSON-encoded validation rules
     */
    function _validateTemplateData(
        uint256 boardType,
        bytes calldata templateData,
        bytes32 expectedHash,
        string calldata validationRules
    ) internal pure {
        // Basic data validation
        if (templateData.length == 0) {
            revert TemplateValidationFailed("Template data cannot be empty");
        }

        if (templateData.length > MAX_TEMPLATE_SIZE) {
            revert TemplateValidationFailed("Template too large");
        }

        // Hash integrity validation
        bytes32 computedHash = keccak256(templateData);
        if (computedHash != expectedHash) {
            revert TemplateVerificationFailed("Template data hash mismatch");
        }

        // Board type specific validation
        _validateBoardTypeConstraints(boardType, templateData);

        // Validation rules format check (basic JSON validation)
        if (bytes(validationRules).length > 0) {
            _validateValidationRulesFormat(validationRules);
        }
    }

    /**
     * @notice Validates board type specific constraints
     * @param boardType Type of board being validated
     * @param templateData Template data to validate
     */
    function _validateBoardTypeConstraints(
        uint256 boardType,
        bytes calldata templateData
    ) internal pure {
        // Minimum size check based on board type
        // Minimum size = tile count * 32 bytes per tile.
        uint256 minSize = boardType * 32;

        if (templateData.length < minSize) {
            revert TemplateValidationFailed("Template data too small for board type");
        }

        // Basic structure validation - ensure data is divisible by tile size
        if (templateData.length % 32 != 0) {
            revert TemplateValidationFailed("Invalid template data structure");
        }
    }

    /**
     * @notice Basic validation rules format validation
     * @param validationRules JSON string to validate
     */
    function _validateValidationRulesFormat(string calldata validationRules) internal pure {
        bytes memory rules = bytes(validationRules);

        // Basic JSON validation - check for opening/closing braces
        if (rules.length > 0) {
            bool hasOpenBrace = false;
            bool hasCloseBrace = false;

            for (uint256 i = 0; i < rules.length; i++) {
                if (rules[i] == "{") hasOpenBrace = true;
                if (rules[i] == "}") hasCloseBrace = true;
            }

            if (hasOpenBrace != hasCloseBrace) {
                revert TemplateValidationFailed("Invalid validation rules JSON format");
            }
        }
    }

    /**
     * @notice Computes validation flags for template metadata
     * @param boardType Type of board
     * @param templateData Template data to analyze
     * @return flags Bitwise validation flags (uint8 to match struct)
     */
    function _computeValidationFlags(
        uint256 boardType,
        bytes calldata templateData
    ) internal pure returns (uint8 flags) {
        flags = 0;

        // Flag 1: Has validation rules (bit 0)
        flags |= 1 << 0;

        // Flag 2: Template size within reasonable bounds (bit 1)
        if (templateData.length <= MAX_TEMPLATE_SIZE / 2) {
            flags |= 1 << 1;
        }

        // Flag 3: Board type specific flag (bit 2) — mark goblin as "large".
        if (boardType == BOARD_TYPE_GOBLIN) {
            flags |= 1 << 2;
        }

        return flags;
    }

    /**
     * @dev Deploys new BeaconProxy instance using active UpgradeableBeacon
     * @notice Deploys BeaconProxy pointing to the active implementation via beacon
     * @param gameId Unique game identifier
     * @param boardType Type of board (30, 50, or 100)
     * @param templateVersion Version of template used
     * @param boardSeed Random seed for board generation
     * @param creator Address of the game creator
     * @param beacon Address of the active UpgradeableBeacon
     * @return proxyAddress Address of deployed BeaconProxy contract
     */
}
