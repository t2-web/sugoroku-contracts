// SPDX-License-Identifier: MIT
// ABOUTME: ERC-721 of the Genesis Summon campaign. Each summon draws a rarity from an on-chain box.
// ABOUTME: One summon per wallet, transfers locked until unlockAt, UUPS upgradeable.
pragma solidity ^0.8.28;

import { ERC721Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title GenesisAdventurer
 * @author Sugoroku Team
 * @notice Adventurer NFTs summoned for free; the relayer pays the gas and holds MINTER_ROLE.
 * @dev Rarity: 0 = COMMON, 1 = UNCOMMON, 2 = RARE, 3 = EPIC, 4 = LEGENDARY.
 *
 *      The box holds a fixed number of tickets per rarity, and a summon removes one.
 *      Every remaining ticket is equally likely, so a rarity's chance is its remaining
 *      count over the total: the odds anyone reads from `boxState` are the real odds.
 *      The roll mixes `entropy` (the keccak256 of the user's summon signature) with the
 *      previous block hash and prevrandao, so the relayer cannot choose the result alone.
 *      The relayer still chooses when to send, so this is weaker than a VRF. That is
 *      accepted for a free campaign.
 *
 *      Token ids run from 1 across boxes. A new box opens only through `openBox`, and only
 *      once the current one is empty.
 */
contract GenesisAdventurer is
    Initializable,
    ERC721Upgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    using Strings for uint256;

    /// @notice Role that may summon. Held by the relayer wallet only.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Number of rarities, COMMON through LEGENDARY.
    uint256 public constant RARITY_COUNT = 5;

    /// @dev Draw state, packed into one slot so a summon writes it once.
    struct Box {
        uint64 summoned; // tokens minted across all boxes; the next token id is summoned + 1
        uint32 number; // current box, 0 before the first openBox
        uint80 left; // remaining tickets, rarity r in bits [16r, 16r + 16)
    }

    // Storage is append-only (UUPS). The OpenZeppelin parents use namespaced storage.
    Box private _box;

    /// @notice Transfers other than mints revert before this timestamp.
    uint64 public unlockAt;

    string private _baseTokenURI;

    /// @notice True once the account has summoned. It stays true if the token moves away.
    mapping(address account => bool summoned) public hasSummoned;

    event Summoned(
        uint256 indexed tokenId,
        address indexed to,
        uint8 rarity,
        uint32 boxNo,
        bool lastOne
    );
    event BoxOpened(uint32 indexed boxNo, uint16[5] counts);
    event UnlockAtUpdated(uint64 unlockAt);
    event BaseURIUpdated(string baseURI);

    error InvalidAddress();
    error AlreadySummoned(address account);
    error SoldOut();
    error BoxNotEmpty();
    error EmptyBox();
    error TransferLocked(uint64 unlockAt);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Sets up the collection with an empty box and transfers locked indefinitely.
     * @dev The admin opens the first box with `openBox` and sets the unlock time with
     *      `setUnlockAt`. MINTER_ROLE is granted separately to the relayer.
     * @param admin Receives DEFAULT_ADMIN_ROLE (box, unlock time, base URI, roles, upgrades)
     * @param name_ ERC-721 name
     * @param symbol_ ERC-721 symbol
     * @param baseURI_ Prefix of `tokenURI`, e.g. https://<domain>/metadata/<chainId>/adventurer/
     */
    function initialize(
        address admin,
        string calldata name_,
        string calldata symbol_,
        string calldata baseURI_
    ) external initializer {
        if (admin == address(0)) revert InvalidAddress();
        __ERC721_init(name_, symbol_);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        unlockAt = type(uint64).max;
        _baseTokenURI = baseURI_;
    }

    // ========================================================================
    // SUMMON
    // ========================================================================

    /**
     * @notice Draws a rarity from the current box and mints the next token to `to`.
     * @param to Wallet that receives the token; it must not have summoned before
     * @param entropy keccak256 of the user's summon signature
     * @return tokenId Serial number, from 1
     * @return rarity Drawn rarity (0..4)
     * @return lastOne True when this summon emptied the box
     */
    function summon(
        address to,
        bytes32 entropy
    ) external onlyRole(MINTER_ROLE) returns (uint256 tokenId, uint8 rarity, bool lastOne) {
        if (hasSummoned[to]) revert AlreadySummoned(to);

        Box memory box = _box;
        uint16[5] memory left = _unpack(box.left);
        uint256 total = _sum(left);
        if (total == 0) revert SoldOut();

        tokenId = uint256(box.summoned) + 1;
        uint256 roll = uint256(
            keccak256(abi.encode(entropy, blockhash(block.number - 1), block.prevrandao, tokenId))
        ) % total;
        rarity = _pickRarity(left, roll);
        lastOne = total == 1;

        // left[rarity] >= 1, so subtracting one in its 16-bit field never borrows.
        _box = Box({
            summoned: box.summoned + 1,
            number: box.number,
            left: box.left - (uint80(1) << (16 * rarity))
        });
        hasSummoned[to] = true;
        _mint(to, tokenId);

        emit Summoned(tokenId, to, rarity, box.number, lastOne);
    }

    // ========================================================================
    // VIEWS
    // ========================================================================

    /// @notice Current box number (0 before the first box) and its remaining tickets per rarity.
    function boxState() external view returns (uint32 boxNo, uint16[5] memory left) {
        Box memory box = _box;
        return (box.number, _unpack(box.left));
    }

    /// @notice Tokens summoned across all boxes. Equals the latest token id.
    function totalSummoned() external view returns (uint256) {
        return _box.summoned;
    }

    /// @notice `baseURI + tokenId + ".json"`, or "" while no base URI is set.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        if (bytes(_baseTokenURI).length == 0) return "";
        return string.concat(_baseTokenURI, tokenId.toString(), ".json");
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721Upgradeable, AccessControlUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // ========================================================================
    // ADMIN
    // ========================================================================

    /**
     * @notice Opens the next box. Only allowed once the current box is empty.
     * @param counts Tickets per rarity, COMMON first; at least one must be non-zero
     */
    function openBox(uint16[5] calldata counts) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Box memory box = _box;
        if (box.left != 0) revert BoxNotEmpty();
        uint80 packed = _pack(counts);
        if (packed == 0) revert EmptyBox();

        uint32 boxNo = box.number + 1;
        _box = Box({ summoned: box.summoned, number: boxNo, left: packed });
        emit BoxOpened(boxNo, counts);
    }

    /// @notice Sets when transfers open. Mints are never locked.
    function setUnlockAt(uint64 timestamp) external onlyRole(DEFAULT_ADMIN_ROLE) {
        unlockAt = timestamp;
        emit UnlockAtUpdated(timestamp);
    }

    /// @notice Sets the `tokenURI` prefix.
    function setBaseURI(string calldata uri) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _baseTokenURI = uri;
        emit BaseURIUpdated(uri);
    }

    // ========================================================================
    // INTERNAL
    // ========================================================================

    /// @dev Locks every transfer except a mint until `unlockAt`, so bots cannot sell before review.
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        if (_ownerOf(tokenId) != address(0) && block.timestamp < unlockAt) {
            revert TransferLocked(unlockAt);
        }
        return super._update(to, tokenId, auth);
    }

    /// @dev roll < sum(left). Rolls [0, left[0]) are rarity 0, the next left[1] rolls rarity 1,
    ///      and so on, so each rarity gets exactly as many rolls as it has tickets.
    function _pickRarity(uint16[5] memory left, uint256 roll) internal pure returns (uint8 rarity) {
        for (; rarity < RARITY_COUNT - 1; ++rarity) {
            if (roll < left[rarity]) return rarity;
            roll -= left[rarity];
        }
    }

    function _unpack(uint80 packed) private pure returns (uint16[5] memory left) {
        for (uint256 r; r < RARITY_COUNT; ++r) {
            left[r] = uint16(packed >> (16 * r));
        }
    }

    function _pack(uint16[5] memory left) private pure returns (uint80 packed) {
        for (uint8 r; r < RARITY_COUNT; ++r) {
            packed |= uint80(left[r]) << (16 * r);
        }
    }

    function _sum(uint16[5] memory left) private pure returns (uint256 total) {
        for (uint256 r; r < RARITY_COUNT; ++r) {
            total += left[r];
        }
    }

    /// @dev Only DEFAULT_ADMIN_ROLE can upgrade.
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
