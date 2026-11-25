// SPDX-License-Identifier: MIT
// ABOUTME: The NFT prize pool of the goal reward, shared by every arena. NFTs stay in one prize wallet that
// ABOUTME: approved this contract; a board reserves one for a goal winner and the winner's exit sends it.
pragma solidity ^0.8.28;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardTransientUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

/**
 * @title GoalNftPrizes
 * @author Sugoroku Team
 * @notice Holds which NFTs each arena (GameBoard) can give as the goal reward's NFT outcome.
 *         The NFTs themselves stay in the prize wallet (`vault`), which has approved this
 *         contract with `setApprovalForAll` once per collection. ERC-721 and ERC-1155 on
 *         the same chain, our DiceNFT (the vault must be on its transfer whitelist) or any
 *         other collection.
 *
 *         1. A board whose goal draw lands on the NFT calls `reserve`: one unit of that
 *            board's stock, every unit equally likely, is set aside for the winner.
 *         2. The winner's exit (their own or the keeper's) calls `deliver`, which sends it
 *            from the vault. A failed send (the vault no longer holds it, the approval was
 *            revoked, the winner is a contract that cannot receive it) leaves an open claim
 *            that anyone can retry with `claim`; it goes to the winner either way.
 *
 * @dev Fairness under gas games: the winner is fixed when the board's move settles. `reserve`
 *      checks the vault with view calls of a fixed gas size and reverts when too little gas
 *      is left for them, so a finalizer cannot starve a check to turn an NFT win into a
 *      percentage redraw. A starved send in `deliver` only opens a claim, which changes
 *      when the NFT arrives, not who gets it.
 *      Roles: DEFAULT_ADMIN_ROLE sets the vault and the boards that may hold stock, grants
 *      roles and upgrades. PRIZE_MANAGER_ROLE registers prizes, stocks those boards and settles
 *      claims. The board list is what keeps a manager from stocking a contract of their own and
 *      reserving the vault's NFTs for themself; with it, a manager alone can send an NFT only
 *      to a goal winner of a listed board.
 *      Which unit a winner gets, and whether any is left, depends on the stock when the move
 *      settles: of two winners of the last unit, the one settled first gets it.
 */
contract GoalNftPrizes is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    UUPSUpgradeable
{
    /// @notice Registers prizes, stocks boards and settles open claims.
    bytes32 public constant PRIZE_MANAGER_ROLE = keccak256("PRIZE_MANAGER_ROLE");

    uint8 public constant STANDARD_ERC721 = 0;
    uint8 public constant STANDARD_ERC1155 = 1;

    /// @notice Most prize kinds one board can stock. Bounds the walk in `reserve` (4 kinds per slot).
    uint256 public constant MAX_STOCK_KINDS = 32;

    /// @dev Gas each vault check in `reserve` gets; `reserve` needs RESERVE_MIN_GAS left to make them.
    uint256 private constant CHECK_GAS = 50_000;
    uint256 private constant RESERVE_MIN_GAS = 3 * CHECK_GAS;
    /// @dev Gas cap of the send in `deliver`: a winner contract that burns all gas it gets
    ///      only opens a claim, instead of making the exit need millions of gas.
    uint256 private constant SEND_GAS = 200_000;

    enum ClaimState {
        None,
        Open,
        Delivered,
        Cancelled
    }

    /// @notice One NFT kind: an ERC-721 token, or one id of an ERC-1155.
    struct Prize {
        address token;
        uint8 standard;
        /// Units in any board's stock, reserved for a winner, or in an open claim
        uint32 outstanding;
        uint256 tokenId;
    }

    /// @notice A won NFT whose send failed or was released; anyone can retry it with `claim`.
    struct Claim {
        address player;
        uint32 prizeId;
        ClaimState state;
        address board;
    }

    // Storage is append-only (UUPS). The OpenZeppelin parents use namespaced storage.
    /// @notice The prize wallet (EOA) that holds every prize NFT
    address public vault;
    Prize[] private _prizes;
    mapping(bytes32 tokenKey => uint256 prizeIdPlusOne) private _prizeIndex;
    /// @dev Per board, (prizeId << 32 | units left), 4 kinds per slot
    mapping(address board => uint64[]) private _stock;
    /// @notice Units a board can still give; `reserve` draws one of them
    mapping(address board => uint256) public totalStock;
    mapping(address board => mapping(address player => uint256 prizeIdPlusOne)) private _reserved;
    Claim[] private _claims;
    uint256[] private _openClaims;
    mapping(uint256 claimId => uint256 indexPlusOne) private _openIndex;
    /// @notice Boards (GameBoard proxies) the admin allows to hold stock
    mapping(address board => bool allowed) public isBoard;

    event VaultChanged(address indexed previousVault, address indexed newVault);
    event BoardSet(address indexed board, bool allowed);
    event PrizeRegistered(
        uint256 indexed prizeId,
        address indexed token,
        uint8 standard,
        uint256 tokenId
    );
    /// @notice A manager changed a board's stock of a prize (not emitted when a goal reserves a unit)
    event StockChanged(
        address indexed board,
        uint256 indexed prizeId,
        uint256 remaining,
        uint256 totalStock
    );
    event PrizeReserved(address indexed board, address indexed player, uint256 indexed prizeId);
    event PrizeDelivered(address indexed board, address indexed player, uint256 indexed prizeId);
    event ClaimOpened(
        uint256 indexed claimId,
        address indexed board,
        address indexed player,
        uint256 prizeId
    );
    event ClaimDelivered(uint256 indexed claimId, address indexed player, uint256 prizeId);
    event ClaimCancelled(uint256 indexed claimId, bool restocked);

    error InvalidAddress();
    error InvalidStandard(uint8 standard);
    error UnknownPrize(uint256 prizeId);
    /// @notice The board is not on the admin's list, so it cannot hold stock
    error UnknownBoard(address board);
    error ZeroAmount();
    /// @param outstanding Units of the prize the pool would then account for
    error VaultShort(uint256 prizeId, uint256 outstanding);
    error VaultNotApproved();
    error TooManyKinds(uint256 max);
    error InsufficientStock(uint256 prizeId, uint256 remaining);
    error NoReservation(address board, address player);
    error ClaimNotOpen(uint256 claimId);
    /// @notice `reserve` was left too little gas for its vault checks
    error InsufficientGas();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param admin Receives DEFAULT_ADMIN_ROLE (vault, roles, upgrades)
     * @param manager Receives PRIZE_MANAGER_ROLE, or address(0) to grant it later
     * @param vault_ The prize wallet
     */
    function initialize(address admin, address manager, address vault_) external initializer {
        if (admin == address(0) || vault_ == address(0)) revert InvalidAddress();
        __AccessControl_init();
        __ReentrancyGuardTransient_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        if (manager != address(0)) _grantRole(PRIZE_MANAGER_ROLE, manager);
        vault = vault_;
        emit VaultChanged(address(0), vault_);
    }

    // ========================================================================
    // BOARD ENTRY POINTS (msg.sender is the board)
    // ========================================================================

    /**
     * @notice Sets one unit of the calling board's stock aside for `player`. Every unit is
     *         equally likely. Called by the board when its goal draw lands on the NFT.
     * @dev Any contract may call it, but only reaches its own stock, which only a manager fills.
     *      A unit the vault cannot send (no longer held, approval revoked, the token's view
     *      fails) is skipped and stays in stock; the board then draws a percentage instead.
     * @return token Prize contract, or address(0) when nothing was reserved
     * @return tokenId Prize token id
     */
    function reserve(
        address player,
        uint256 random
    ) external returns (address token, uint256 tokenId) {
        address board = msg.sender;
        uint256 total = totalStock[board];
        if (total == 0) return (address(0), 0);

        uint64[] storage list = _stock[board];
        uint256 ticket = random % total;
        uint256 index;
        uint256 entry;
        for (; ; ++index) {
            entry = list[index];
            uint256 left = entry & type(uint32).max;
            if (ticket < left) break;
            ticket -= left;
        }
        uint256 prizeId = entry >> 32;
        Prize storage p = _prizes[prizeId];
        token = p.token;
        tokenId = p.tokenId;
        if (!_vaultCanSend(token, p.standard, tokenId)) return (address(0), 0);

        if (entry & type(uint32).max == 1) {
            _removeKind(list, index);
        } else {
            list[index] = uint64(entry - 1);
        }
        totalStock[board] = total - 1;

        // A reservation left over from an earlier entry (its exit did not reach `deliver`)
        // becomes an open claim, so no prize is lost.
        uint256 previous = _reserved[board][player];
        if (previous != 0) _openClaim(board, player, previous - 1);
        _reserved[board][player] = prizeId + 1;
        emit PrizeReserved(board, player, prizeId);
    }

    /**
     * @notice Sends `player`'s reserved prize, if any. Called by the board when the player exits.
     * @dev Never reverts on a failed send: the prize becomes an open claim instead, so an exit
     *      cannot be blocked by the NFT.
     */
    function deliver(address player) external nonReentrant {
        address board = msg.sender;
        uint256 prizeIdPlusOne = _reserved[board][player];
        if (prizeIdPlusOne == 0) return;
        delete _reserved[board][player];

        uint256 prizeId = prizeIdPlusOne - 1;
        Prize storage p = _prizes[prizeId];
        if (_trySend(p, player)) {
            --p.outstanding;
            emit PrizeDelivered(board, player, prizeId);
        } else {
            _openClaim(board, player, prizeId);
        }
    }

    // ========================================================================
    // CLAIMS
    // ========================================================================

    /**
     * @notice Sends an open claim's NFT to its winner. Anyone may call it (the winner, the
     *         keeper, a manager); the NFT only ever goes to the winner. Reverts if the send fails.
     */
    function claim(uint256 claimId) external nonReentrant {
        Claim storage c = _requireOpen(claimId);
        c.state = ClaimState.Delivered;
        _closeOpen(claimId);
        Prize storage p = _prizes[c.prizeId];
        --p.outstanding;
        if (p.standard == STANDARD_ERC721) {
            IERC721(p.token).safeTransferFrom(vault, c.player, p.tokenId);
        } else {
            IERC1155(p.token).safeTransferFrom(vault, c.player, p.tokenId, 1, "");
        }
        emit ClaimDelivered(claimId, c.player, c.prizeId);
    }

    /**
     * @notice Closes an open claim without sending it, e.g. when the winner can never receive
     *         the NFT. `restock` puts the unit back into the board's stock.
     */
    function cancelClaim(uint256 claimId, bool restock) external onlyRole(PRIZE_MANAGER_ROLE) {
        Claim storage c = _requireOpen(claimId);
        c.state = ClaimState.Cancelled;
        _closeOpen(claimId);
        if (restock) {
            _addToStock(c.board, c.prizeId, 1);
        } else {
            --_prizes[c.prizeId].outstanding;
        }
        emit ClaimCancelled(claimId, restock);
    }

    /**
     * @notice Turns a reservation into an open claim. Only for a board that can no longer call
     *         `deliver` (e.g. retired); a player still in the game would get the NFT before exiting.
     */
    function releaseReservation(
        address board,
        address player
    ) external onlyRole(PRIZE_MANAGER_ROLE) {
        uint256 prizeIdPlusOne = _reserved[board][player];
        if (prizeIdPlusOne == 0) revert NoReservation(board, player);
        delete _reserved[board][player];
        _openClaim(board, player, prizeIdPlusOne - 1);
    }

    // ========================================================================
    // PRIZES AND STOCK
    // ========================================================================

    /**
     * @notice Allows or stops a board (a GameBoard proxy) to hold stock. Stopping it blocks new
     *         stock only; remove what it holds with removeStock.
     */
    function setBoard(address board, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (allowed && board.code.length == 0) revert InvalidAddress();
        isBoard[board] = allowed;
        emit BoardSet(board, allowed);
    }

    /// @notice Changes the prize wallet. Move the NFTs and their approvals first.
    function setVault(address newVault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newVault == address(0)) revert InvalidAddress();
        emit VaultChanged(vault, newVault);
        vault = newVault;
    }

    /**
     * @notice Adds an NFT kind to the catalog, or returns its id if it is already there.
     * @param standard STANDARD_ERC721 or STANDARD_ERC1155; the token must report it (ERC-165)
     */
    function registerPrize(
        address token,
        uint8 standard,
        uint256 tokenId
    ) external onlyRole(PRIZE_MANAGER_ROLE) returns (uint256 prizeId) {
        if (token.code.length == 0) revert InvalidAddress();
        if (standard > STANDARD_ERC1155) revert InvalidStandard(standard);
        bytes4 interfaceId = standard == STANDARD_ERC721
            ? type(IERC721).interfaceId
            : type(IERC1155).interfaceId;
        if (!_supportsInterface(token, interfaceId)) revert InvalidStandard(standard);

        bytes32 key = keccak256(abi.encode(token, tokenId));
        uint256 prizeIdPlusOne = _prizeIndex[key];
        if (prizeIdPlusOne != 0) return prizeIdPlusOne - 1;
        prizeId = _prizes.length;
        // Stock entries and claims keep the id in 32 bits.
        if (prizeId > type(uint32).max) revert UnknownPrize(prizeId);
        _prizes.push(Prize({ token: token, standard: standard, outstanding: 0, tokenId: tokenId }));
        _prizeIndex[key] = prizeId + 1;
        emit PrizeRegistered(prizeId, token, standard, tokenId);
    }

    /**
     * @notice Adds units of a registered prize to a board's stock. The vault must hold every
     *         unit the pool accounts for and have approved this contract; an ERC-721 token can
     *         be stocked once across all boards.
     */
    function addStock(
        address board,
        uint256 prizeId,
        uint256 amount
    ) external onlyRole(PRIZE_MANAGER_ROLE) {
        if (!isBoard[board]) revert UnknownBoard(board);
        if (amount == 0) revert ZeroAmount();
        Prize storage p = _prize(prizeId);
        uint256 outstanding = p.outstanding + amount;
        if (outstanding > type(uint32).max) revert VaultShort(prizeId, outstanding);
        address vault_ = vault;
        if (p.standard == STANDARD_ERC721) {
            if (outstanding > 1 || IERC721(p.token).ownerOf(p.tokenId) != vault_) {
                revert VaultShort(prizeId, outstanding);
            }
        } else if (IERC1155(p.token).balanceOf(vault_, p.tokenId) < outstanding) {
            revert VaultShort(prizeId, outstanding);
        }
        // IERC721 and IERC1155 share the isApprovedForAll(address,address) selector.
        if (!IERC721(p.token).isApprovedForAll(vault_, address(this))) revert VaultNotApproved();
        _addToStock(board, prizeId, amount);
        p.outstanding = uint32(outstanding);
    }

    /// @notice Takes units of a prize out of a board's stock (reserved units are not affected).
    function removeStock(
        address board,
        uint256 prizeId,
        uint256 amount
    ) external onlyRole(PRIZE_MANAGER_ROLE) {
        if (amount == 0) revert ZeroAmount();
        uint64[] storage list = _stock[board];
        uint256 index = _findKind(list, prizeId);
        uint256 left = index == type(uint256).max ? 0 : list[index] & type(uint32).max;
        if (amount > left) revert InsufficientStock(prizeId, left);
        left -= amount;
        if (left == 0) {
            _removeKind(list, index);
        } else {
            list[index] = uint64((prizeId << 32) | left);
        }
        uint256 total = totalStock[board] - amount;
        totalStock[board] = total;
        _prizes[prizeId].outstanding -= uint32(amount);
        emit StockChanged(board, prizeId, left, total);
    }

    // ========================================================================
    // VIEWS
    // ========================================================================

    function prizeCount() external view returns (uint256) {
        return _prizes.length;
    }

    function getPrize(uint256 prizeId) external view returns (Prize memory) {
        return _prize(prizeId);
    }

    /// @return found Whether the token is registered
    /// @return prizeId Its prize id when found
    function prizeIdOf(
        address token,
        uint256 tokenId
    ) external view returns (bool found, uint256 prizeId) {
        uint256 prizeIdPlusOne = _prizeIndex[keccak256(abi.encode(token, tokenId))];
        return (prizeIdPlusOne != 0, prizeIdPlusOne == 0 ? 0 : prizeIdPlusOne - 1);
    }

    /// @notice A board's stock: prize ids and the units left of each
    function stockOf(
        address board
    ) external view returns (uint256[] memory prizeIds, uint256[] memory remaining) {
        uint64[] storage list = _stock[board];
        uint256 len = list.length;
        prizeIds = new uint256[](len);
        remaining = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            uint256 entry = list[i];
            prizeIds[i] = entry >> 32;
            remaining[i] = entry & type(uint32).max;
        }
    }

    /// @notice The prize reserved for `player` on `board`, sent when they exit
    function reservationOf(
        address board,
        address player
    ) external view returns (bool reserved, uint256 prizeId) {
        uint256 prizeIdPlusOne = _reserved[board][player];
        return (prizeIdPlusOne != 0, prizeIdPlusOne == 0 ? 0 : prizeIdPlusOne - 1);
    }

    function claimCount() external view returns (uint256) {
        return _claims.length;
    }

    function getClaim(uint256 claimId) external view returns (Claim memory) {
        return _claims[claimId];
    }

    /// @notice Ids of every open claim (unsent prizes), for retries by the keeper
    function openClaims() external view returns (uint256[] memory) {
        return _openClaims;
    }

    // ========================================================================
    // INTERNAL
    // ========================================================================

    function _prize(uint256 prizeId) private view returns (Prize storage) {
        if (prizeId >= _prizes.length) revert UnknownPrize(prizeId);
        return _prizes[prizeId];
    }

    function _requireOpen(uint256 claimId) private view returns (Claim storage c) {
        if (claimId >= _claims.length || _claims[claimId].state != ClaimState.Open) {
            revert ClaimNotOpen(claimId);
        }
        c = _claims[claimId];
    }

    function _openClaim(address board, address player, uint256 prizeId) private {
        uint256 claimId = _claims.length;
        _claims.push(
            Claim({
                player: player,
                prizeId: uint32(prizeId),
                state: ClaimState.Open,
                board: board
            })
        );
        _openClaims.push(claimId);
        _openIndex[claimId] = _openClaims.length;
        emit ClaimOpened(claimId, board, player, prizeId);
    }

    function _closeOpen(uint256 claimId) private {
        uint256 index = _openIndex[claimId] - 1;
        uint256 last = _openClaims[_openClaims.length - 1];
        _openClaims[index] = last;
        _openIndex[last] = index + 1;
        _openClaims.pop();
        delete _openIndex[claimId];
    }

    /// @dev Callers account for the units in Prize.outstanding.
    function _addToStock(address board, uint256 prizeId, uint256 amount) private {
        uint64[] storage list = _stock[board];
        uint256 index = _findKind(list, prizeId);
        uint256 left = amount;
        if (index == type(uint256).max) {
            if (list.length == MAX_STOCK_KINDS) revert TooManyKinds(MAX_STOCK_KINDS);
            list.push();
            index = list.length - 1;
        } else {
            left += list[index] & type(uint32).max;
        }
        // left never exceeds the prize's outstanding units, which fit in uint32.
        list[index] = uint64((prizeId << 32) | left);
        uint256 total = totalStock[board] + amount;
        totalStock[board] = total;
        emit StockChanged(board, prizeId, left, total);
    }

    /// @return Index of the prize in the list, or type(uint256).max when absent
    function _findKind(uint64[] storage list, uint256 prizeId) private view returns (uint256) {
        uint256 len = list.length;
        for (uint256 i; i < len; ++i) {
            if (list[i] >> 32 == prizeId) return i;
        }
        return type(uint256).max;
    }

    function _removeKind(uint64[] storage list, uint256 index) private {
        uint256 last = list.length - 1;
        if (index != last) list[index] = list[last];
        list.pop();
    }

    /// @dev Both views get CHECK_GAS each; with less gas left than that the move reverts instead.
    function _vaultCanSend(
        address token,
        uint8 standard,
        uint256 tokenId
    ) private view returns (bool) {
        if (gasleft() < RESERVE_MIN_GAS) revert InsufficientGas();
        address vault_ = vault;
        (bool ok, uint256 value) = _view(
            token,
            standard == STANDARD_ERC721
                ? abi.encodeCall(IERC721.ownerOf, (tokenId))
                : abi.encodeCall(IERC1155.balanceOf, (vault_, tokenId))
        );
        if (!ok || (standard == STANDARD_ERC721 ? value != uint256(uint160(vault_)) : value == 0)) {
            return false;
        }
        (ok, value) = _view(
            token,
            abi.encodeCall(IERC721.isApprovedForAll, (vault_, address(this)))
        );
        return ok && value == 1;
    }

    /// @dev One-word static call with CHECK_GAS; ok is false when it reverts or returns less.
    function _view(
        address target,
        bytes memory data
    ) private view returns (bool ok, uint256 value) {
        assembly ("memory-safe") {
            ok := staticcall(CHECK_GAS, target, add(data, 0x20), mload(data), 0x00, 0x20)
            if lt(returndatasize(), 0x20) {
                ok := 0
            }
            value := mload(0x00)
        }
    }

    function _trySend(Prize storage p, address to) private returns (bool) {
        address vault_ = vault;
        if (p.standard == STANDARD_ERC721) {
            try IERC721(p.token).safeTransferFrom{ gas: SEND_GAS }(vault_, to, p.tokenId) {
                return true;
            } catch {
                return false;
            }
        }
        try IERC1155(p.token).safeTransferFrom{ gas: SEND_GAS }(vault_, to, p.tokenId, 1, "") {
            return true;
        } catch {
            return false;
        }
    }

    function _supportsInterface(address token, bytes4 interfaceId) private view returns (bool) {
        try IERC165(token).supportsInterface(interfaceId) returns (bool supported) {
            return supported;
        } catch {
            return false;
        }
    }

    /// @dev Only DEFAULT_ADMIN_ROLE can upgrade.
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
