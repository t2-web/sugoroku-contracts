// SPDX-License-Identifier: MIT
// ABOUTME: Holds pre-minted Dice NFTs (one token id per arena, as DiceNFT registers them) and sends the
// ABOUTME: Genesis Summon rewards from that stock to the player's wallet. It can never mint; each claimId pays once.
pragma solidity ^0.8.28;

import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ERC1155HolderUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";

/// @dev The DiceNFT reads the pool needs besides ERC-1155: which ids are arenas' Dice NFTs.
interface IDiceNftRegistry is IERC1155 {
    function isDiceRegistered(uint256 id) external view returns (bool);
    function diceIds() external view returns (uint256[] memory);
}

/**
 * @title SummonDiceClaim
 * @author Sugoroku Team
 * @notice The reward pool of Genesis Summon. The DiceNFT owner mints the rewards into this
 *         contract ahead of time; `grant` sends them from that stock to the player's wallet.
 *         The relayer sends `grant` and pays its gas. The player turns the NFTs into dice
 *         on the game screen through DiceNFTRedeemer, paying that gas.
 * @dev The pool holds no DiceNFT minting right and no GameBoard role, so a leaked relayer
 *      key or a bug here can lose at most the stock. The stock is the only cap.
 *      The number of arenas is not fixed: any id the DiceNFT registers can be granted, and
 *      the DiceNFT's `diceInfo(id)` says which arena and GameBoard the id belongs to.
 */
contract SummonDiceClaim is
    Initializable,
    AccessControlUpgradeable,
    ERC1155HolderUpgradeable,
    UUPSUpgradeable
{
    /// @notice Role that may call `grant`. Held by the relayer wallet only.
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

    // Storage is append-only (UUPS). The OpenZeppelin parents use namespaced storage.
    IDiceNftRegistry private _diceNft;

    /// @notice True once a claimId has been granted.
    mapping(bytes32 claimId => bool done) public claimed;

    event DiceGranted(
        bytes32 indexed claimId,
        address indexed player,
        uint256[] ids,
        uint256[] amounts
    );
    event StockWithdrawn(address indexed to, uint256[] ids, uint256[] amounts);

    error InvalidAddress();
    error AlreadyClaimed(bytes32 claimId);
    /// @notice `ids` and `amounts` differ in length or are empty.
    error InvalidBatch();
    /// @param id A token id given with a zero amount
    error ZeroAmount(uint256 id);
    /// @param id A token id given twice in one batch
    error DuplicateId(uint256 id);
    /// @param id A token id the DiceNFT has not registered for any arena
    error UnregisteredDice(uint256 id);
    /// @param id The token id that is short
    /// @param available NFTs of that id left in the pool
    error OutOfStock(uint256 id, uint256 available);
    /// @param token The ERC-1155 contract that tried to send to the pool
    error UnsupportedToken(address token);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param admin Receives DEFAULT_ADMIN_ROLE (withdraw, roles, upgrades)
     * @param diceNft_ The DiceNFT ERC-1155 whose tokens the pool holds
     */
    function initialize(address admin, address diceNft_) external initializer {
        if (admin == address(0) || diceNft_ == address(0)) revert InvalidAddress();
        __AccessControl_init();
        __ERC1155Holder_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _diceNft = IDiceNftRegistry(diceNft_);
    }

    /**
     * @notice Sends the reward NFTs from the stock to the player. All or nothing: one bad or
     *         short id reverts the whole grant and leaves the claimId unused.
     * @param player Wallet that receives the NFTs
     * @param claimId keccak256("summon-claim", wallet, round), made by the API
     * @param ids DiceNFT token ids (registered arenas), each once
     * @param amounts NFTs per id, each non-zero
     */
    function grant(
        address player,
        bytes32 claimId,
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) external onlyRole(RELAYER_ROLE) {
        if (player == address(0)) revert InvalidAddress();
        if (claimed[claimId]) revert AlreadyClaimed(claimId);
        claimed[claimId] = true;
        _checkStock(ids, amounts);

        emit DiceGranted(claimId, player, ids, amounts);
        _diceNft.safeBatchTransferFrom(address(this), player, ids, amounts, "");
    }

    /**
     * @notice Takes NFTs out of the stock, e.g. to stop the pool at once or after the campaign.
     * @param to Wallet or contract that receives them
     * @param ids DiceNFT token ids, each once
     * @param amounts NFTs per id, each non-zero
     */
    function withdraw(
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert InvalidAddress();
        _checkStock(ids, amounts);

        emit StockWithdrawn(to, ids, amounts);
        _diceNft.safeBatchTransferFrom(address(this), to, ids, amounts, "");
    }

    /// @notice NFTs left in the pool for every id the DiceNFT registers, in its `diceIds()` order.
    function stock() external view returns (uint256[] memory ids, uint256[] memory amounts) {
        ids = _diceNft.diceIds();
        amounts = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            amounts[i] = _diceNft.balanceOf(address(this), ids[i]);
        }
    }

    /// @notice The DiceNFT contract the pool holds.
    function diceNft() external view returns (address) {
        return address(_diceNft);
    }

    /// @dev Accepts only the DiceNFT, so no other token can get stuck here.
    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes memory data
    ) public override returns (bytes4) {
        _onlyDiceNft();
        return super.onERC1155Received(operator, from, id, value, data);
    }

    /// @dev Accepts only the DiceNFT, so no other token can get stuck here.
    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    ) public override returns (bytes4) {
        _onlyDiceNft();
        return super.onERC1155BatchReceived(operator, from, ids, values, data);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControlUpgradeable, ERC1155HolderUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /// @dev Reverts unless every id is registered, given once with a non-zero amount, and in stock.
    function _checkStock(uint256[] calldata ids, uint256[] calldata amounts) private view {
        if (ids.length == 0 || ids.length != amounts.length) revert InvalidBatch();
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            if (amounts[i] == 0) revert ZeroAmount(id);
            for (uint256 j; j < i; ++j) {
                if (ids[j] == id) revert DuplicateId(id);
            }
            if (!_diceNft.isDiceRegistered(id)) revert UnregisteredDice(id);
            uint256 available = _diceNft.balanceOf(address(this), id);
            if (amounts[i] > available) revert OutOfStock(id, available);
        }
    }

    function _onlyDiceNft() private view {
        if (msg.sender != address(_diceNft)) revert UnsupportedToken(msg.sender);
    }

    /// @dev Only DEFAULT_ADMIN_ROLE can upgrade.
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
