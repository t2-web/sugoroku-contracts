// ABOUTME: Production ERC-1155 DiceNFT used as the burnable source for DiceNFTRedeemer. One token id per arena,
// ABOUTME: registered on-chain with its board and name. Soulbound: holders can only burn or use the owner's whitelist.
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ERC1155Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import { ERC1155BurnableUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155BurnableUpgradeable.sol";
import { ERC1155SupplyUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155SupplyUpgradeable.sol";

/**
 * @title DiceNFT
 * @notice Burnable ERC-1155 dice inventory for Sugoroku promotional redemptions.
 * @dev Each token id is one arena's Dice NFT (2026-11-10 decision): `diceInfo(id)` names the
 *      arena and the GameBoard it is used on (1 Goblin, 2 Slime, 3 Orc, 4 Dragon). The owner
 *      registers a new arena's id and re-points an id when its arena's board is rebuilt; the id
 *      itself never changes. Only registered ids can be minted. WHITE_DICE/GREEN_DICE/RED_DICE
 *      keep their old names for the ABI (ids 1/2/3) and the 3-id helpers stay for old callers.
 *      Soulbound (2026-11-09 decision): while `transfersOpen` is false, a transfer between two
 *      accounts reverts unless one side is on `transferWhitelist` (the Genesis Summon reward pool
 *      sending rewards, a team contract receiving them) or the owner sends it while recovery
 *      transfers are on (`adminTransferEnabled`, for `adminTransfer`). Minting and burning stay
 *      open, so DiceNFTRedeemer still burns for dice. Whitelist only contracts the team controls
 *      that never let a third party take NFTs out (no market or escrow): such a contract would
 *      unlock them.
 */
contract DiceNFT is
    Initializable,
    ERC1155SupplyUpgradeable,
    ERC1155BurnableUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    uint256 public constant WHITE_DICE = 1;
    uint256 public constant GREEN_DICE = 2;
    uint256 public constant RED_DICE = 3;

    address public farmingContract;
    bool public adminTransferEnabled;

    /// @notice Accounts a DiceNFT may move from or to while transfers are closed.
    mapping(address account => bool allowed) public transferWhitelist;
    /// @notice True lets every holder transfer as plain ERC-1155. False (the default) makes the NFTs soulbound.
    bool public transfersOpen;

    /// @notice One arena's Dice NFT: the GameBoard it is used on and the arena's name ("Goblin").
    struct DiceInfo {
        address board;
        string name;
    }

    /// @dev Registered ids; a zero board means the id is not registered.
    mapping(uint256 id => DiceInfo info) private _diceInfo;
    /// @dev Registered ids in registration order, for enumeration.
    uint256[] private _diceIdList;
    /// @notice The id registered for a GameBoard; 0 when none. One board has at most one id.
    mapping(address board => uint256 id) public diceIdOfBoard;

    uint256[43] private __gap;

    event DiceSeedMinted(address indexed to, uint256 indexed tokenId, uint256 amount);
    event BatchDiceSeedMinted(address indexed operator, address[] recipients);
    event DiceSeedBurned(address indexed from, uint256 indexed tokenId, uint256 amount);
    event FarmingContractUpdated(
        address indexed previousFarmingContract,
        address indexed replacementFarmingContract
    );
    event AdminTransferEnabledUpdated(bool enabled);
    event BaseURIUpdated(string uri);
    event TransferWhitelistUpdated(address indexed account, bool allowed);
    event TransfersOpenUpdated(bool open);
    event DiceRegistered(uint256 indexed id, address indexed board, string name);
    event DiceBoardUpdated(
        uint256 indexed id,
        address indexed previousBoard,
        address indexed board
    );
    event DiceRenamed(uint256 indexed id, string name);

    error InvalidAddress();
    error InvalidDiceId(uint256 tokenId);
    error ArrayLengthMismatch();
    error Unauthorized();
    error AdminTransferDisabled();
    error TransferNotAllowed(address from, address to);
    error DiceAlreadyRegistered(uint256 id);
    error BoardAlreadyRegistered(address board, uint256 id);
    error EmptyName();
    error EmptyBatch();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(string memory baseUri) external initializer {
        __ERC1155_init(baseUri);
        __ERC1155Supply_init();
        __ERC1155Burnable_init();
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }

    /**
     * @notice Registers arenas in the same transaction as the upgrade that adds the registry
     *         (`upgradeToAndCall`). Runs once; owner only, so nobody can front-run it on a fresh proxy.
     * @param ids Token ids, e.g. [1, 2, 3, 4]
     * @param boards GameBoard proxy of each id's arena
     * @param names Arena name of each id, the arena's GameToken `name()` (e.g. "Goblin")
     */
    function initializeDiceRegistry(
        uint256[] calldata ids,
        address[] calldata boards,
        string[] calldata names
    ) external reinitializer(2) onlyOwner {
        if (ids.length != boards.length || ids.length != names.length) {
            revert ArrayLengthMismatch();
        }
        for (uint256 i = 0; i < ids.length; i++) {
            _registerDice(ids[i], boards[i], names[i]);
        }
    }

    /// @notice Registers a new arena's Dice NFT. The id is explicit and can never be reused.
    function registerDice(uint256 id, address board, string calldata name) external onlyOwner {
        _registerDice(id, board, name);
    }

    /// @notice Points a registered id at its arena's new GameBoard (the arena was rebuilt).
    function setDiceBoard(uint256 id, address board) external onlyOwner {
        address previous = _registeredBoard(id);
        _claimBoard(board, id);
        delete diceIdOfBoard[previous];
        _diceInfo[id].board = board;
        emit DiceBoardUpdated(id, previous, board);
    }

    /// @notice Renames a registered id's arena.
    function setDiceName(uint256 id, string calldata name) external onlyOwner {
        _registeredBoard(id);
        if (bytes(name).length == 0) revert EmptyName();
        _diceInfo[id].name = name;
        emit DiceRenamed(id, name);
    }

    function mint(address to, uint256 id, uint256 amount) external onlyOwnerOrFarming {
        _validateRecipient(to);
        _validateDiceId(id);
        _mint(to, id, amount, "");
        emit DiceSeedMinted(to, id, amount);
    }

    function mintBatch(
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) external onlyOwnerOrFarming {
        _validateRecipient(to);
        _validateDiceIds(ids);
        _mintBatch(to, ids, amounts, "");
        for (uint256 i = 0; i < ids.length; i++) {
            emit DiceSeedMinted(to, ids[i], amounts[i]);
        }
    }

    /**
     * @notice Mint W/G/R dice to many users in one admin call.
     * @param recipients Wallets to receive dice.
     * @param amountsByRecipient For each wallet: [whiteAmount, greenAmount, redAmount].
     */
    function adminBatchMintToMultiple(
        address[] calldata recipients,
        uint256[][] calldata amountsByRecipient
    ) external onlyOwner {
        if (recipients.length != amountsByRecipient.length) revert ArrayLengthMismatch();

        uint256[] memory ids = _diceIds();
        _validateDiceIds(ids);
        for (uint256 i = 0; i < recipients.length; i++) {
            _validateRecipient(recipients[i]);
            if (amountsByRecipient[i].length != 3) revert ArrayLengthMismatch();

            uint256[] memory amounts = new uint256[](3);
            amounts[0] = amountsByRecipient[i][0];
            amounts[1] = amountsByRecipient[i][1];
            amounts[2] = amountsByRecipient[i][2];
            _mintBatch(recipients[i], ids, amounts, "");
        }

        emit BatchDiceSeedMinted(msg.sender, recipients);
    }

    /**
     * @notice Mint any registered ids (Dragon, id 4, included) to many users in one admin call.
     * @dev Same shape and event as `adminBatchMintToMultiple`, with the ids given by the caller
     *      instead of the fixed 1/2/3. The per-recipient amounts go to `_mintBatch` unchanged:
     *      each recipient gets one `TransferBatch` with its ids and amounts, or one `TransferSingle`
     *      when `ids` has a single entry (OpenZeppelin's ERC-1155 picks the event by length).
     * @param recipients Wallets to receive dice.
     * @param ids Registered token ids, the same for every recipient (e.g. [1, 2, 3, 4]).
     * @param amountsByRecipient For each wallet, one amount per entry of `ids` (zero allowed).
     */
    function adminBatchMintIds(
        address[] calldata recipients,
        uint256[] calldata ids,
        uint256[][] calldata amountsByRecipient
    ) external onlyOwner {
        if (recipients.length == 0 || ids.length == 0) revert EmptyBatch();
        if (recipients.length != amountsByRecipient.length) revert ArrayLengthMismatch();

        _validateDiceIds(ids);
        for (uint256 i = 0; i < recipients.length; i++) {
            _validateRecipient(recipients[i]);
            if (amountsByRecipient[i].length != ids.length) revert ArrayLengthMismatch();
            _mintBatch(recipients[i], ids, amountsByRecipient[i], "");
        }

        emit BatchDiceSeedMinted(msg.sender, recipients);
    }

    function setFarmingContract(address replacementFarmingContract) external onlyOwner {
        address old = farmingContract;
        farmingContract = replacementFarmingContract;
        emit FarmingContractUpdated(old, replacementFarmingContract);
    }

    function setAdminTransferEnabled(bool enabled) external onlyOwner {
        adminTransferEnabled = enabled;
        emit AdminTransferEnabledUpdated(enabled);
    }

    /// @notice Lets `account` send or receive DiceNFTs while transfers are closed (or takes that back).
    function setTransferWhitelist(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert InvalidAddress();
        transferWhitelist[account] = allowed;
        emit TransferWhitelistUpdated(account, allowed);
    }

    /// @notice Opens transfers for every holder (true) or makes the NFTs soulbound again (false).
    function setTransfersOpen(bool open) external onlyOwner {
        transfersOpen = open;
        emit TransfersOpenUpdated(open);
    }

    function setURI(string calldata replacementUri) external onlyOwner {
        _setURI(replacementUri);
        emit BaseURIUpdated(replacementUri);
    }

    function adminTransfer(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external onlyOwner {
        if (!adminTransferEnabled) revert AdminTransferDisabled();
        _validateDiceId(id);
        _safeTransferFrom(from, to, id, amount, data);
    }

    function adminBatchTransfer(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external onlyOwner {
        if (!adminTransferEnabled) revert AdminTransferDisabled();
        _validateDiceIds(ids);
        _safeBatchTransferFrom(from, to, ids, amounts, data);
    }

    /**
     * @notice The collection's name, which explorers and wallets read by convention: ERC-1155 has no
     *         `name()`, and without one BscScan labels the collection "BEP-1155". A constant, so the
     *         upgrade that adds it stores nothing. Each id's own name stays in `diceInfo(id)` and `uri(id)`.
     */
    function name() external pure returns (string memory) {
        return "SUGOROKU Dice NFT";
    }

    /// @notice The collection's ticker symbol, read by explorers and wallets like `name()`.
    function symbol() external pure returns (string memory) {
        return "DICE";
    }

    /// @notice The arena of a token id; a zero board means the id is not registered.
    function diceInfo(uint256 id) external view returns (DiceInfo memory) {
        return _diceInfo[id];
    }

    /// @notice Every registered token id, in registration order.
    function diceIds() external view returns (uint256[] memory) {
        return _diceIdList;
    }

    /// @notice True when `id` is registered (and so can be minted).
    function isDiceRegistered(uint256 id) public view returns (bool) {
        return _diceInfo[id].board != address(0);
    }

    /// @notice `user`'s balance of every registered id, in `diceIds()` order.
    function balancesOf(
        address user
    ) external view returns (uint256[] memory ids, uint256[] memory balances) {
        ids = _diceIdList;
        balances = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            balances[i] = balanceOf(user, ids[i]);
        }
    }

    /// @notice The total supply of every registered id, in `diceIds()` order.
    function totalSupplies()
        external
        view
        returns (uint256[] memory ids, uint256[] memory supplies)
    {
        ids = _diceIdList;
        supplies = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            supplies[i] = totalSupply(ids[i]);
        }
    }

    function getUserBalances(
        address user
    ) external view returns (uint256 white, uint256 green, uint256 red) {
        white = balanceOf(user, WHITE_DICE);
        green = balanceOf(user, GREEN_DICE);
        red = balanceOf(user, RED_DICE);
    }

    function getRarityCounts() external view returns (uint256 white, uint256 green, uint256 red) {
        white = totalSupply(WHITE_DICE);
        green = totalSupply(GREEN_DICE);
        red = totalSupply(RED_DICE);
    }

    function burn(address account, uint256 id, uint256 value) public override {
        super.burn(account, id, value);
        emit DiceSeedBurned(account, id, value);
    }

    function burnBatch(
        address account,
        uint256[] memory ids,
        uint256[] memory values
    ) public override {
        super.burnBatch(account, ids, values);
        for (uint256 i = 0; i < ids.length; i++) {
            emit DiceSeedBurned(account, ids[i], values[i]);
        }
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC1155Upgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override(ERC1155Upgradeable, ERC1155SupplyUpgradeable) {
        // Mint (from 0) and burn (to 0) pass; a transfer between accounts needs an open gate,
        // a whitelisted side, or the owner while recovery transfers are on. The switch matters:
        // without it the owner could also move a holder's NFTs through a plain safeTransferFrom
        // after the holder approved the owner as an operator.
        if (
            from != address(0) &&
            to != address(0) &&
            !transfersOpen &&
            !transferWhitelist[from] &&
            !transferWhitelist[to] &&
            !(adminTransferEnabled && _msgSender() == owner())
        ) {
            revert TransferNotAllowed(from, to);
        }
        super._update(from, to, ids, values);
    }

    function _authorizeUpgrade(address implementationAddress) internal view override onlyOwner {
        if (implementationAddress == address(0)) revert InvalidAddress();
    }

    modifier onlyOwnerOrFarming() {
        if (msg.sender != owner() && msg.sender != farmingContract) revert Unauthorized();
        _;
    }

    function _validateRecipient(address to) private pure {
        if (to == address(0)) revert InvalidAddress();
    }

    function _validateDiceIds(uint256[] memory ids) private view {
        for (uint256 i = 0; i < ids.length; i++) {
            _validateDiceId(ids[i]);
        }
    }

    /// @dev Only registered ids can be minted or moved by the owner's recovery transfer.
    function _validateDiceId(uint256 id) private view {
        if (!isDiceRegistered(id)) revert InvalidDiceId(id);
    }

    function _registerDice(uint256 id, address board, string calldata name) private {
        if (id == 0) revert InvalidDiceId(id);
        if (isDiceRegistered(id)) revert DiceAlreadyRegistered(id);
        if (bytes(name).length == 0) revert EmptyName();
        _claimBoard(board, id);
        _diceInfo[id] = DiceInfo({ board: board, name: name });
        _diceIdList.push(id);
        emit DiceRegistered(id, board, name);
    }

    /// @dev Reserves `board` for `id`; a board serves one arena only.
    function _claimBoard(address board, uint256 id) private {
        if (board == address(0)) revert InvalidAddress();
        uint256 holder = diceIdOfBoard[board];
        if (holder != 0) revert BoardAlreadyRegistered(board, holder);
        diceIdOfBoard[board] = id;
    }

    /// @dev The board of a registered id; reverts when `id` is not registered.
    function _registeredBoard(uint256 id) private view returns (address board) {
        board = _diceInfo[id].board;
        if (board == address(0)) revert InvalidDiceId(id);
    }

    function _diceIds() private pure returns (uint256[] memory ids) {
        ids = new uint256[](3);
        ids[0] = WHITE_DICE;
        ids[1] = GREEN_DICE;
        ids[2] = RED_DICE;
    }
}
