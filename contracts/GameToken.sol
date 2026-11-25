// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/**
 * @title GameToken
 * @notice Per-game ERC-20 token, deployed once per game via BeaconProxy.
 * @dev Admin (Registry) receives the full initialSupply at initialize(). Additional
 *      supply may be minted later via mint() by DEFAULT_ADMIN_ROLE (the Registry)
 *      to support pair-with-USDC liquidity top-ups. No cap — the Registry gate is
 *      the sole economic constraint. Pause halts transfers.
 */
contract GameToken is
    Initializable,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable
{
    error InvalidAdmin();
    error InvalidSupply();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize a per-game token.
     * @param name_ Token name.
     * @param symbol_ Token symbol.
     * @param initialSupply Full initial supply minted to `admin`.
     * @param admin Address that receives DEFAULT_ADMIN_ROLE and the initial supply
     *              (expected to be the Registry, which seeds liquidity from this balance).
     */
    function initialize(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply,
        address admin
    ) external initializer {
        if (admin == address(0)) revert InvalidAdmin();
        if (initialSupply == 0) revert InvalidSupply();

        __ERC20_init(name_, symbol_);
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _mint(admin, initialSupply);
    }

    /**
     * @notice Mint additional tokens to `to`. Admin only.
     * @dev Registry calls this when pairing newly minted tokens with USDC to
     *      top up the AMM pool (see Registry.addLiquidity). Price is preserved
     *      off-chain/off-band by quoting against current reserves before mint.
     */
    function mint(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _mint(to, amount);
    }

    /// @notice Pause transfers. Admin only.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpause transfers. Admin only.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @dev Hook: block transfers while paused.
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override whenNotPaused {
        super._update(from, to, value);
    }

    /// @dev Storage gap for future upgrades.
    uint256[50] private __gap;
}
