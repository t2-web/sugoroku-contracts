// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/**
 * @title IGameBoardRedeemer
 * @dev Minimal interface for GameBoard functions used by the Redeemer
 */
interface IGameBoardRedeemer {
    function addPlayer(address player) external returns (uint256 startPosition);
    function grantDice(address player, uint256 diceAmount) external;
}

/**
 * @title IDiceNFT
 * @dev Interface for the external DiceNFT ERC-1155 contract
 */
interface IDiceNFT {
    function burn(address account, uint256 id, uint256 value) external;
    function burnBatch(address account, uint256[] calldata ids, uint256[] calldata values) external;
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function getUserBalances(
        address user
    ) external view returns (uint256 white, uint256 green, uint256 red);
    function isApprovedForAll(address account, address operator) external view returns (bool);
}

/**
 * @title DiceNFTRedeemer
 * @dev Burns external ERC-1155 DiceNFTs and grants in-game dice on per-rarity
 *      routed SugorokuGameBoards. UUPS upgradeable proxy.
 *
 * v2 (multi-game routing):
 *   - Each DiceNFT tokenId fans out to up to 3 destination GameBoards via the
 *     `diceGrants` mapping. Each grant entry carries (gameBoard, dicePerNft).
 *     One burn batch -> one grantDice call per unique destination board.
 *   - The legacy single-game `gameBoard` field and scalar `conversionRates`
 *     map are retained in storage for ABI/upgrade compatibility but are NOT
 *     consulted by the redeem logic.
 *   - `setDiceNft(address)` lets the owner swap the underlying ERC-1155
 *     (e.g. point at a MockDiceNFT for testing). User approvals do NOT carry
 *     over -- testers must `setApprovalForAll` again on the new DiceNFT.
 *
 * Flow:
 *   1. User approves this contract on the DiceNFT (setApprovalForAll)
 *   2. User calls redeemDice (existing player on every destination) or
 *      redeemAndJoin (auto-adds player to each destination first)
 *   3. Contract burns NFTs, fans out per-board grantDice based on diceGrants
 *
 * @author Sugoroku Team
 */
contract DiceNFTRedeemer is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Maximum destination GameBoards for a single DiceNFT tokenId.
    uint256 public constant MAX_DICE_GRANTS = 3;

    // ========================================================================
    // STORAGE -- DO NOT REORDER OR REMOVE EXISTING SLOTS (UUPS upgrade safety)
    // ========================================================================

    /// @notice Legacy: single-game target. v2 ignores this value; kept for ABI
    ///         and storage-layout compatibility with v1.
    address public gameBoard;

    /// @notice External DiceNFT ERC-1155 contract. Mutable via setDiceNft().
    address public diceNft;

    /// @notice Legacy: tokenId => NFTs-per-dice. v2 ignores; superseded by
    ///         diceGrants. Kept for storage-layout compatibility.
    mapping(uint256 => uint256) public conversionRates;

    /// @notice Total NFTs burned per tokenId (for dashboard stats)
    mapping(uint256 => uint256) public totalBurned;

    /// @notice Total dice granted across all redemptions (summed across boards)
    uint256 public totalDiceGranted;

    /// @notice Total number of redemption transactions
    uint256 public totalRedemptions;

    /// @notice v2: per-rarity routing. tokenId => list of (gameBoard, dicePerNft).
    /// @dev Packed: address (20B) + uint96 (12B) = 32B = one slot per entry.
    struct DiceGrant {
        address gameBoard;
        uint96 dicePerNft;
    }
    mapping(uint256 => DiceGrant[]) private _diceGrants;

    /// @notice Reserved storage for future upgrades.
    /// @dev v1 had __gap[44]; v2 consumes one slot for `_diceGrants` so the
    ///      gap is [43].
    uint256[43] private __gap;

    // ========================================================================
    // EVENTS
    // ========================================================================

    event DiceRedeemed(
        address indexed player,
        uint256[] tokenIds,
        uint256[] amounts,
        uint256 totalDice
    );

    /// @notice Legacy v1 event, kept for ABI compatibility. Not emitted by v2.
    event ConversionRateUpdated(uint256 indexed tokenId, uint256 nftsPerDice);

    event GameBoardUpdated(address indexed oldBoard, address indexed newBoard);

    event DiceGrantsUpdated(uint256 indexed tokenId, DiceGrant[] grants);

    event DiceNftUpdated(address indexed oldDiceNft, address indexed newDiceNft);

    // ========================================================================
    // ERRORS
    // ========================================================================

    error InvalidAddress();
    error ArrayLengthMismatch();
    error EmptyArrays();
    error ConversionRateNotSet(uint256 tokenId);
    error InvalidRedeemAmount(uint256 tokenId, uint256 amount, uint256 rate);
    error InvalidConversionRate();
    error TooManyBoards(); // > MAX_DICE_GRANTS destinations in one redeem
    error InvalidGrantConfig(); // grants.length out of [1, MAX_DICE_GRANTS] or zero dicePerNft

    // ========================================================================
    // CONSTRUCTOR & INITIALIZER
    // ========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the redeemer with target GameBoard and DiceNFT addresses.
     * @dev v2 retains the v1 initialize signature for ABI compatibility, but
     *      the `_gameBoard` argument is now legacy (stored, not used by redeem
     *      logic). Set routes via setDiceGrants after deploy.
     * @param _gameBoard Legacy GameBoard address (kept for storage compat)
     * @param _diceNft Address of the DiceNFT ERC-1155 contract
     * @param _owner Address that will own this contract (admin)
     */
    function initialize(address _gameBoard, address _diceNft, address _owner) external initializer {
        if (_gameBoard == address(0) || _diceNft == address(0) || _owner == address(0)) {
            revert InvalidAddress();
        }

        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        gameBoard = _gameBoard;
        diceNft = _diceNft;
    }

    // ========================================================================
    // REDEEM FUNCTIONS
    // ========================================================================

    /**
     * @notice Burn DiceNFTs and grant in-game dice on every routed GameBoard.
     * @param tokenIds Array of DiceNFT token IDs to burn (WHITE/GREEN/RED dice)
     * @param amounts Array of NFT amounts to burn per tokenId
     * @return totalDice Total dice granted (summed across all destination boards)
     */
    function redeemDice(
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) external nonReentrant whenNotPaused returns (uint256 totalDice) {
        totalDice = _redeemDice(msg.sender, tokenIds, amounts);
    }

    /**
     * @notice Add the caller to every routed GameBoard (best-effort) then
     *         burn DiceNFTs and grant dice on each.
     * @dev `addPlayer` reverts on "already a player", "game inactive", or
     *      "MaxPlayersReached" are all swallowed by try/catch. Pre-launch this
     *      is acceptable; revisit before public launch for finer control.
     * @param tokenIds Array of DiceNFT token IDs to burn
     * @param amounts Array of NFT amounts to burn per tokenId
     * @return totalDice Total dice granted (summed across all destination boards)
     */
    function redeemAndJoin(
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) external nonReentrant whenNotPaused returns (uint256 totalDice) {
        if (tokenIds.length != amounts.length) revert ArrayLengthMismatch();
        if (tokenIds.length == 0) revert EmptyArrays();

        // Collect the unique destination boards across all rarities being burned
        address[MAX_DICE_GRANTS] memory destBoards;
        uint256 destLen;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            DiceGrant[] storage grants = _diceGrants[tokenIds[i]];
            for (uint256 j = 0; j < grants.length; j++) {
                address b = grants[j].gameBoard;
                uint256 k;
                bool found = false;
                for (k = 0; k < destLen; k++) {
                    if (destBoards[k] == b) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    if (destLen == MAX_DICE_GRANTS) revert TooManyBoards();
                    destBoards[destLen++] = b;
                }
            }
        }

        // Best-effort addPlayer on each destination
        for (uint256 k = 0; k < destLen; k++) {
            try IGameBoardRedeemer(destBoards[k]).addPlayer(msg.sender) returns (
                uint256
            ) {} catch {}
        }

        totalDice = _redeemDice(msg.sender, tokenIds, amounts);
    }

    // ========================================================================
    // INTERNAL
    // ========================================================================

    /**
     * @dev Shared logic: validate inputs, fan out per-board dice totals,
     *      single burn batch, per-board grantDice calls.
     */
    function _redeemDice(
        address player,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) internal returns (uint256 totalDice) {
        if (tokenIds.length != amounts.length) revert ArrayLengthMismatch();
        if (tokenIds.length == 0) revert EmptyArrays();

        // Up to MAX_DICE_GRANTS unique destination boards across the redemption.
        address[MAX_DICE_GRANTS] memory boards;
        uint256[MAX_DICE_GRANTS] memory perBoardDice;
        uint256 boardsLen;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            DiceGrant[] storage grants = _diceGrants[tokenIds[i]];
            if (grants.length == 0) revert ConversionRateNotSet(tokenIds[i]);
            if (amounts[i] == 0) revert InvalidRedeemAmount(tokenIds[i], amounts[i], 1);

            for (uint256 j = 0; j < grants.length; j++) {
                uint256 add = amounts[i] * uint256(grants[j].dicePerNft);
                address g = grants[j].gameBoard;

                uint256 k;
                bool found = false;
                for (k = 0; k < boardsLen; k++) {
                    if (boards[k] == g) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    if (boardsLen == MAX_DICE_GRANTS) revert TooManyBoards();
                    boards[boardsLen] = g;
                    k = boardsLen;
                    boardsLen++;
                }
                perBoardDice[k] += add;
                totalDice += add;
            }

            totalBurned[tokenIds[i]] += amounts[i];
        }

        // Single burn for all NFTs (requires prior setApprovalForAll on diceNft)
        IDiceNFT(diceNft).burnBatch(player, tokenIds, amounts);

        // Per-board grants
        for (uint256 k = 0; k < boardsLen; k++) {
            IGameBoardRedeemer(boards[k]).grantDice(player, perBoardDice[k]);
        }

        totalDiceGranted += totalDice;
        totalRedemptions++;

        emit DiceRedeemed(player, tokenIds, amounts, totalDice);
    }

    // ========================================================================
    // ADMIN CONFIGURATION
    // ========================================================================

    /**
     * @notice Set the routing for a DiceNFT tokenId. Overwrites prior grants.
     * @param tokenId The DiceNFT token ID (e.g. WHITE_DICE=1)
     * @param grants Destination boards + dicePerNft. Length in [1, MAX_DICE_GRANTS].
     */
    function setDiceGrants(uint256 tokenId, DiceGrant[] calldata grants) external onlyOwner {
        if (grants.length == 0 || grants.length > MAX_DICE_GRANTS) revert InvalidGrantConfig();
        for (uint256 i = 0; i < grants.length; i++) {
            if (grants[i].gameBoard == address(0)) revert InvalidAddress();
            if (grants[i].dicePerNft == 0) revert InvalidGrantConfig();
        }
        delete _diceGrants[tokenId];
        for (uint256 i = 0; i < grants.length; i++) {
            _diceGrants[tokenId].push(grants[i]);
        }
        emit DiceGrantsUpdated(tokenId, grants);
    }

    /// @notice View the configured routing for a DiceNFT tokenId.
    function getDiceGrants(uint256 tokenId) external view returns (DiceGrant[] memory) {
        return _diceGrants[tokenId];
    }

    /**
     * @notice Re-point the Redeemer at a different DiceNFT contract. Used to
     *         switch to MockDiceNFT for testing on HyperEVM mainnet.
     * @dev Per-user `setApprovalForAll` granted on the previous DiceNFT does
     *      NOT carry over. Users must re-approve on the new DiceNFT before
     *      the next redemption.
     */
    function setDiceNft(address _diceNft) external onlyOwner {
        if (_diceNft == address(0)) revert InvalidAddress();
        address old = diceNft;
        diceNft = _diceNft;
        emit DiceNftUpdated(old, _diceNft);
    }

    /**
     * @notice Legacy v1 setter. Retained for ABI compatibility; v2 redeem
     *         logic does not consult `conversionRates`. Use `setDiceGrants`.
     * @dev Still writes the legacy slot so off-chain tooling reading the slot
     *      doesn't break.
     */
    function setConversionRate(uint256 tokenId, uint256 nftsPerDice) external onlyOwner {
        if (nftsPerDice == 0) revert InvalidConversionRate();
        conversionRates[tokenId] = nftsPerDice;
        emit ConversionRateUpdated(tokenId, nftsPerDice);
    }

    /**
     * @notice Legacy v1 setter. Retained for ABI compatibility; v2 redeem
     *         logic uses `_diceGrants[tokenId][i].gameBoard` instead of the
     *         singleton `gameBoard`.
     */
    function setGameBoard(address _gameBoard) external onlyOwner {
        if (_gameBoard == address(0)) revert InvalidAddress();
        address oldBoard = gameBoard;
        gameBoard = _gameBoard;
        emit GameBoardUpdated(oldBoard, _gameBoard);
    }

    /// @notice Pause all redemptions.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause redemptions.
    function unpause() external onlyOwner {
        _unpause();
    }

    // ========================================================================
    // UUPS UPGRADE AUTHORIZATION
    // ========================================================================

    /// @dev Only the owner can authorize upgrades.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
