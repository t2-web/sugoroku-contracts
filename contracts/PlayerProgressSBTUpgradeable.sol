// SPDX-License-Identifier: MIT
// ABOUTME: Upgradeable (UUPS) successor of PlayerProgressSBT with the same metric ABI.
// ABOUTME: Adds setURI and a one-time, closable copy of metrics from the legacy SBT.
pragma solidity ^0.8.28;

import { ERC1155Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @dev Read side of the legacy PlayerProgressSBT that migrateFrom copies from.
interface ILegacyPlayerProgressSBT {
    function getPlayerMetrics(
        address player,
        uint256 gameId
    ) external view returns (uint256 ownedSgp, uint256 earnedSgp, uint256 dicePurchased);
}

/**
 * @title PlayerProgressSBTUpgradeable
 * @author Sugoroku Team
 * @notice Soulbound ERC-1155 that stores per-player, per-game progress metrics.
 * @dev Token ID = (gameId << 16) | metricId, metricId 1 = Owned SGP, 2 = Earned SGP,
 *      3 = Dice Purchased. Same ABI and events as the legacy PlayerProgressSBT, so the
 *      GameBoard, frontend and admin dashboard need no changes.
 *
 *      Differences from the legacy contract:
 *      - UUPS upgradeable; only DEFAULT_ADMIN_ROLE can upgrade.
 *      - The initializer does not give the deployer ENGINE_ROLE. Only GameBoards get it.
 *      - `uri()` is the plain OpenZeppelin `{id}` template and `setURI` can change it.
 *      - Balances are written through `_update`, never `_mint`/`_burn`, so no
 *        ERC-1155 receiver callback runs. A player that is a contract or an EIP-7702
 *        account without `onERC1155Received` would otherwise make every move revert.
 *        Transfer events are still emitted.
 *      - `migrateFrom` copies metrics from an allowlisted legacy SBT until
 *        `closeMigration` is called.
 *
 * @custom:security-contact security@sugoroku.example.com
 */
contract PlayerProgressSBTUpgradeable is
    Initializable,
    ERC1155Upgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    /// @notice Role identifier for the game engine (only entity that can update metrics)
    bytes32 public constant ENGINE_ROLE = keccak256("ENGINE_ROLE");

    /// @notice Metric ID for Owned SGP (current balance)
    uint256 public constant METRIC_OWNED_SGP = 1;

    /// @notice Metric ID for Earned SGP (cumulative total)
    uint256 public constant METRIC_EARNED_SGP = 2;

    /// @notice Metric ID for Dice Purchased (cumulative count)
    uint256 public constant METRIC_DICE_PURCHASED = 3;

    /// @custom:storage-location erc7201:sugoroku.storage.PlayerProgressSBT
    struct SbtStorage {
        mapping(address source => bool allowed) legacySources;
        bool migrationClosed;
    }

    // keccak256(abi.encode(uint256(keccak256("sugoroku.storage.PlayerProgressSBT")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SBT_STORAGE_LOCATION =
        0xd9596dc97019dc93ef748d0050e48ab57d95254bc8329ee2355481e36898cc00;

    /// @notice Thrown when attempting any transfer or approval operation (SBT behavior)
    error SBT_Disabled();

    /// @notice Kept for ABI parity with the legacy SBT; access is enforced by AccessControl
    error NotEngine();

    /// @notice Thrown when an invalid game ID is provided (e.g., zero)
    error InvalidGameId();

    /// @notice Thrown when an invalid player address is provided (e.g., zero address)
    error InvalidPlayer();

    /// @notice Thrown when attempting to decrease OwnedSGP below zero
    /// @param requested The amount requested to subtract
    /// @param available The current available balance
    error InsufficientBalance(uint256 requested, uint256 available);

    /// @notice Thrown when initialize receives the zero address as admin or legacy source
    error ZeroAddress();

    /// @notice Thrown when migrateFrom names a source that was not allowlisted at initialize
    /// @param source The rejected source
    error UnknownLegacySource(address source);

    /// @notice Thrown when migrateFrom is called after closeMigration
    error MigrationIsClosed();

    /**
     * @notice Emitted when any player metric is updated
     * @param player Address of the player
     * @param gameId Identifier of the game instance
     * @param metricId The metric type (1=OwnedSGP, 2=EarnedSGP, 3=DicePurchased)
     * @param oldValue Previous value
     * @param newValue New value
     */
    event MetricUpdated(
        address indexed player,
        uint256 indexed gameId,
        uint256 indexed metricId,
        uint256 oldValue,
        uint256 newValue
    );

    /**
     * @notice Emitted when an administrator corrects erroneous progress metrics
     * @param admin Address of the administrator who made the correction
     * @param player Address of the player whose progress was corrected
     * @param gameId Identifier of the game instance
     * @param justification Explanation for why the correction was necessary
     * @param oldValues Array of previous values [ownedSgp, earnedSgp, dicePurchased]
     * @param newValues Array of corrected values [ownedSgp, earnedSgp, dicePurchased]
     */
    event AdminCorrectionApplied(
        address indexed admin,
        address indexed player,
        uint256 indexed gameId,
        string justification,
        uint256[3] oldValues,
        uint256[3] newValues
    );

    /**
     * @notice Emitted when the admin replaces the base metadata URI
     * @param uri The new base URI (still contains the `{id}` placeholder)
     */
    event BaseURIUpdated(string uri);

    /**
     * @notice Emitted when migrateFrom changes one metric to the legacy value
     * @param source Legacy SBT the value was read from
     * @param player Address of the player
     * @param gameId Identifier of the game instance
     * @param metricId The metric type (1=OwnedSGP, 2=EarnedSGP, 3=DicePurchased)
     * @param oldValue Value in this SBT before the copy
     * @param newValue Value copied from the legacy SBT
     */
    event MetricMigrated(
        address indexed source,
        address indexed player,
        uint256 indexed gameId,
        uint256 metricId,
        uint256 oldValue,
        uint256 newValue
    );

    /// @notice Emitted once, when the admin permanently disables migrateFrom
    event MigrationClosed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the proxy
     * @param uri_ Base URI containing the ERC-1155 `{id}` placeholder
     * @param admin Receives DEFAULT_ADMIN_ROLE (upgrades, roles, corrections, migration)
     * @param legacySources SBT contracts migrateFrom may copy from
     */
    function initialize(
        string calldata uri_,
        address admin,
        address[] calldata legacySources
    ) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        __ERC1155_init(uri_);
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        SbtStorage storage $ = _sbtStorage();
        for (uint256 i = 0; i < legacySources.length; i++) {
            if (legacySources[i] == address(0)) revert ZeroAddress();
            $.legacySources[legacySources[i]] = true;
        }
    }

    // ========================================================================
    // SBT behaviour
    // ========================================================================

    /// @inheritdoc ERC1155Upgradeable
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC1155Upgradeable, AccessControlUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /// @notice Disabled: SBT tokens cannot be approved for transfer
    function setApprovalForAll(address, bool) public pure override {
        revert SBT_Disabled();
    }

    /// @notice Disabled: SBT tokens cannot be transferred
    function safeTransferFrom(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) public pure override {
        revert SBT_Disabled();
    }

    /// @notice Disabled: SBT tokens cannot be batch transferred
    function safeBatchTransferFrom(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) public pure override {
        revert SBT_Disabled();
    }

    // ========================================================================
    // Metric writes
    // ========================================================================

    /**
     * @notice Batch update all three metrics for a player
     * @dev Same semantics and events as the legacy SBT: owned may go up or down but not
     *      below zero, earned and dice only increase. MetricUpdated is always emitted for
     *      owned, and for earned and dice only when they change.
     * @param player Address of the player to update
     * @param gameId Identifier of the game instance
     * @param ownedDelta Change in Owned SGP (can be positive or negative)
     * @param earnedAdd Amount to add to Earned SGP
     * @param diceAdd Number of dice to add
     */
    function batchUpdatePlayer(
        address player,
        uint256 gameId,
        int256 ownedDelta,
        uint256 earnedAdd,
        uint256 diceAdd
    ) external onlyRole(ENGINE_ROLE) {
        _validate(player, gameId);

        uint256 ownedId = _makeTokenId(gameId, METRIC_OWNED_SGP);
        uint256 oldOwned = balanceOf(player, ownedId);
        uint256 newOwned = oldOwned;
        if (ownedDelta > 0) {
            newOwned = oldOwned + uint256(ownedDelta);
            _write(address(0), player, ownedId, uint256(ownedDelta));
        } else if (ownedDelta < 0) {
            uint256 amount = uint256(-ownedDelta);
            if (oldOwned < amount) revert InsufficientBalance(amount, oldOwned);
            newOwned = oldOwned - amount;
            _write(player, address(0), ownedId, amount);
        }
        emit MetricUpdated(player, gameId, METRIC_OWNED_SGP, oldOwned, newOwned);

        _addMonotonic(player, gameId, METRIC_EARNED_SGP, earnedAdd);
        _addMonotonic(player, gameId, METRIC_DICE_PURCHASED, diceAdd);
    }

    /**
     * @notice Administrative correction of a player's metrics
     * @param player Address of the player whose metrics to correct
     * @param gameId Identifier of the game instance
     * @param newOwnedSgp Corrected value for Owned SGP
     * @param newEarnedSgp Corrected value for Earned SGP
     * @param newDicePurchased Corrected value for Dice Purchased
     * @param justification Mandatory explanation for the correction (audit trail)
     */
    function adminCorrectMetrics(
        address player,
        uint256 gameId,
        uint256 newOwnedSgp,
        uint256 newEarnedSgp,
        uint256 newDicePurchased,
        string calldata justification
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validate(player, gameId);
        require(bytes(justification).length > 0, "Justification required");

        uint256[3] memory oldValues = [
            _setMetric(player, gameId, METRIC_OWNED_SGP, newOwnedSgp),
            _setMetric(player, gameId, METRIC_EARNED_SGP, newEarnedSgp),
            _setMetric(player, gameId, METRIC_DICE_PURCHASED, newDicePurchased)
        ];

        emit AdminCorrectionApplied(
            msg.sender,
            player,
            gameId,
            justification,
            oldValues,
            [newOwnedSgp, newEarnedSgp, newDicePurchased]
        );
    }

    // ========================================================================
    // Migration from the legacy SBT
    // ========================================================================

    /**
     * @notice Overwrites each player's three metrics in `gameId` with the values held by
     *         `source`. Pre-cutover only: once boards write to this SBT, a copy would
     *         replace real progress with stale legacy values. SbtCutoverExecutor closes
     *         the migration in the cutover transaction for that reason.
     * @dev Values are read from the source in this call, never passed in, so the admin
     *      cannot mint arbitrary balances through this path. Only metrics that differ are
     *      written, so calling it again with the same input changes nothing.
     * @param source Legacy SBT allowlisted at initialize
     * @param gameId Identifier of the game instance
     * @param players Players to copy
     */
    function migrateFrom(
        address source,
        uint256 gameId,
        address[] calldata players
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        SbtStorage storage $ = _sbtStorage();
        if ($.migrationClosed) revert MigrationIsClosed();
        if (!$.legacySources[source]) revert UnknownLegacySource(source);
        if (gameId == 0) revert InvalidGameId();

        for (uint256 i = 0; i < players.length; i++) {
            address player = players[i];
            if (player == address(0)) revert InvalidPlayer();
            (uint256 owned, uint256 earned, uint256 dice) = ILegacyPlayerProgressSBT(source)
                .getPlayerMetrics(player, gameId);
            _migrateMetric(source, player, gameId, METRIC_OWNED_SGP, owned);
            _migrateMetric(source, player, gameId, METRIC_EARNED_SGP, earned);
            _migrateMetric(source, player, gameId, METRIC_DICE_PURCHASED, dice);
        }
    }

    /// @notice Permanently disables migrateFrom
    function closeMigration() external onlyRole(DEFAULT_ADMIN_ROLE) {
        SbtStorage storage $ = _sbtStorage();
        if ($.migrationClosed) revert MigrationIsClosed();
        $.migrationClosed = true;
        emit MigrationClosed();
    }

    /// @notice True when migrateFrom accepts `source`
    function isLegacySource(address source) external view returns (bool) {
        return _sbtStorage().legacySources[source];
    }

    /// @notice True once closeMigration has been called
    function migrationClosed() external view returns (bool) {
        return _sbtStorage().migrationClosed;
    }

    // ========================================================================
    // Metadata
    // ========================================================================

    /**
     * @notice Replaces the ERC-1155 base metadata URI for every token
     * @param newUri New base URI. Keep the literal `{id}` placeholder; clients replace it
     *        with the 64-digit lowercase hex token ID.
     */
    function setURI(string calldata newUri) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setURI(newUri);
        emit BaseURIUpdated(newUri);
    }

    // ========================================================================
    // Reads
    // ========================================================================

    /**
     * @notice Retrieves all three metrics for a single player in a specific game
     * @param player Address of the player to query
     * @param gameId Identifier of the game instance
     * @return ownedSgp Current Owned SGP balance
     * @return earnedSgp Cumulative Earned SGP
     * @return dicePurchased Total Dice Purchased count
     */
    function getPlayerMetrics(
        address player,
        uint256 gameId
    ) external view returns (uint256 ownedSgp, uint256 earnedSgp, uint256 dicePurchased) {
        ownedSgp = balanceOf(player, _makeTokenId(gameId, METRIC_OWNED_SGP));
        earnedSgp = balanceOf(player, _makeTokenId(gameId, METRIC_EARNED_SGP));
        dicePurchased = balanceOf(player, _makeTokenId(gameId, METRIC_DICE_PURCHASED));
    }

    /**
     * @notice Retrieves metrics for multiple player-game pairs
     * @param players Array of player addresses to query
     * @param gameIds Array of game identifiers (must match players length)
     * @return ownedSgp Array of Owned SGP balances
     * @return earnedSgp Array of Earned SGP totals
     * @return dicePurchased Array of Dice Purchased counts
     */
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
        )
    {
        require(players.length == gameIds.length, "Array length mismatch");
        uint256 length = players.length;
        ownedSgp = new uint256[](length);
        earnedSgp = new uint256[](length);
        dicePurchased = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            ownedSgp[i] = balanceOf(players[i], _makeTokenId(gameIds[i], METRIC_OWNED_SGP));
            earnedSgp[i] = balanceOf(players[i], _makeTokenId(gameIds[i], METRIC_EARNED_SGP));
            dicePurchased[i] = balanceOf(
                players[i],
                _makeTokenId(gameIds[i], METRIC_DICE_PURCHASED)
            );
        }
    }

    // ========================================================================
    // Internals
    // ========================================================================

    /// @dev Only DEFAULT_ADMIN_ROLE can upgrade the implementation.
    function _authorizeUpgrade(address) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function _validate(address player, uint256 gameId) private pure {
        if (player == address(0)) revert InvalidPlayer();
        if (gameId == 0) revert InvalidGameId();
    }

    function _addMonotonic(
        address player,
        uint256 gameId,
        uint256 metricId,
        uint256 amount
    ) private {
        if (amount == 0) return;
        uint256 tokenId = _makeTokenId(gameId, metricId);
        uint256 oldValue = balanceOf(player, tokenId);
        _write(address(0), player, tokenId, amount);
        emit MetricUpdated(player, gameId, metricId, oldValue, oldValue + amount);
    }

    function _migrateMetric(
        address source,
        address player,
        uint256 gameId,
        uint256 metricId,
        uint256 target
    ) private {
        uint256 oldValue = _setMetric(player, gameId, metricId, target);
        if (oldValue != target) {
            emit MetricMigrated(source, player, gameId, metricId, oldValue, target);
        }
    }

    /// @dev Moves a metric to `target` by minting or burning only the difference.
    function _setMetric(
        address player,
        uint256 gameId,
        uint256 metricId,
        uint256 target
    ) private returns (uint256 oldValue) {
        uint256 tokenId = _makeTokenId(gameId, metricId);
        oldValue = balanceOf(player, tokenId);
        if (target > oldValue) {
            _write(address(0), player, tokenId, target - oldValue);
        } else if (target < oldValue) {
            _write(player, address(0), tokenId, oldValue - target);
        }
    }

    /// @dev Mint (from = 0) or burn (to = 0) one token without the receiver callback.
    function _write(address from, address to, uint256 tokenId, uint256 amount) private {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory values = new uint256[](1);
        ids[0] = tokenId;
        values[0] = amount;
        _update(from, to, ids, values);
    }

    function _makeTokenId(uint256 gameId, uint256 metricId) private pure returns (uint256) {
        return (gameId << 16) | metricId;
    }

    function _sbtStorage() private pure returns (SbtStorage storage $) {
        assembly {
            $.slot := SBT_STORAGE_LOCATION
        }
    }
}
