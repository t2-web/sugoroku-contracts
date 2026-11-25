// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ABOUTME: On-chain rolling 7-day hourly price history for per-game AMM pools.
// ABOUTME: UUPS singleton — pools push observations, the frontend reads them.

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./IGamePriceOracle.sol";

/// @title GamePriceOracle
/// @author Sugoroku Team
/// @notice Stores a rolling 7-day, hourly price history for every game's AMM
///         pool. A pool pushes one observation per hourly bucket via the lazy
///         record-on-swap hook in SugorokuAMMPool.
/// @dev Display-only feed. NOT manipulation-resistant — never read this from
///      on-chain logic. Observations are keyed by the calling pool address, so
///      `record` is safely permissionless: an unknown caller can only write
///      into its own isolated buffer, which no consumer reads.
contract GamePriceOracle is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    IGamePriceOracle
{
    // ═══════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Role for admin operations (contract upgrades).
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Seconds per observation bucket (1 hour).
    uint256 public constant BUCKET_SECONDS = 3600;

    /// @notice Number of buckets retained: 7 days × 24 hours.
    uint256 public constant WINDOW = 168;

    // ═══════════════════════════════════════════════════════════════════════
    //                               TYPES
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice A single price observation. Reserves are stored raw (not a
    ///         derived price) so the reading is exact; consumers compute
    ///         price = reserve0 / reserve1 with the correct token decimals.
    /// @dev Packs into one 256-bit storage slot (112 + 112 + 32 = 256 bits).
    struct Observation {
        uint112 reserve0; // payment-token reserve at record time
        uint112 reserve1; // game-token reserve at record time
        uint32 timestamp; // block.timestamp at record time; 0 marks an empty slot
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                           STATE VARIABLES
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice pool => ring buffer of WINDOW observations, indexed by hour % WINDOW.
    mapping(address => Observation[WINDOW]) private _history;

    /// @notice pool => most recent hour bucket recorded.
    mapping(address => uint32) private _lastHour;

    /// @dev Reserved storage space for future upgrades.
    uint256[48] private __gap;

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emitted when an observation is stored for a pool.
    /// @param pool Pool the observation belongs to (the caller).
    /// @param hour Hour bucket index (block.timestamp / BUCKET_SECONDS).
    /// @param reserve0 Recorded payment-token reserve.
    /// @param reserve1 Recorded game-token reserve.
    /// @param timestamp block.timestamp at record time.
    event PriceRecorded(
        address indexed pool,
        uint32 indexed hour,
        uint112 reserve0,
        uint112 reserve1,
        uint32 timestamp
    );

    // ═══════════════════════════════════════════════════════════════════════
    //                           CUSTOM ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Thrown when an address argument is the zero address.
    error InvalidAddress();

    // ═══════════════════════════════════════════════════════════════════════
    //                           CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Initialize the oracle.
    /// @param admin Address granted DEFAULT_ADMIN_ROLE and ADMIN_ROLE.
    function initialize(address admin) external initializer {
        if (admin == address(0)) revert InvalidAddress();

        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          RECORD FUNCTION
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IGamePriceOracle
    function record(uint112 reserve0, uint112 reserve1) external override {
        uint32 hour = uint32(block.timestamp / BUCKET_SECONDS);

        // One write per pool per bucket. The caller (an AMM pool) already
        // guards this, but the check makes the oracle correct on its own.
        if (_lastHour[msg.sender] == hour) return;
        _lastHour[msg.sender] = hour;

        uint32 ts = uint32(block.timestamp);
        _history[msg.sender][hour % WINDOW] = Observation({
            reserve0: reserve0,
            reserve1: reserve1,
            timestamp: ts
        });

        emit PriceRecorded(msg.sender, hour, reserve0, reserve1, ts);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Return every stored observation for a pool, oldest first.
    /// @dev View-only — empty (timestamp 0) ring-buffer slots are skipped and
    ///      the result is sorted ascending by timestamp.
    /// @param pool Pool address to read history for.
    /// @return observations Up to WINDOW observations, oldest to newest.
    function getHistory(address pool) external view returns (Observation[] memory observations) {
        Observation[WINDOW] storage buf = _history[pool];

        uint256 count;
        for (uint256 i = 0; i < WINDOW; i++) {
            if (buf[i].timestamp != 0) count++;
        }

        observations = new Observation[](count);
        uint256 j;
        for (uint256 i = 0; i < WINDOW; i++) {
            if (buf[i].timestamp != 0) {
                observations[j++] = buf[i];
            }
        }

        // Insertion sort ascending by timestamp. count <= WINDOW (168) and this
        // is a view function, so the O(n^2) cost is irrelevant.
        for (uint256 i = 1; i < count; i++) {
            Observation memory key = observations[i];
            uint256 k = i;
            while (k > 0 && observations[k - 1].timestamp > key.timestamp) {
                observations[k] = observations[k - 1];
                k--;
            }
            observations[k] = key;
        }
    }

    /// @notice Return the most recent observation for a pool.
    /// @dev Returns a zero-valued Observation (timestamp 0) if the pool has no
    ///      recorded history.
    /// @param pool Pool address to read.
    /// @return observation The latest stored observation.
    function getLatest(address pool) external view returns (Observation memory observation) {
        observation = _history[pool][_lastHour[pool] % WINDOW];
    }

    /// @notice Return the most recent hour bucket recorded for a pool.
    /// @param pool Pool address to read.
    /// @return hour Hour bucket index, or 0 if the pool has no history.
    function lastRecordedHour(address pool) external view returns (uint32 hour) {
        hour = _lastHour[pool];
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        UPGRADE AUTHORIZATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Restricts UUPS upgrades to ADMIN_ROLE.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {
        if (newImplementation == address(0)) revert InvalidAddress();
    }
}
