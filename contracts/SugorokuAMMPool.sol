// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ABOUTME: Constant-product AMM pool for token0↔token1 swaps
// ABOUTME: Restricted access - admin liquidity, game contracts swap only
// ABOUTME: Deployed once per game behind a BeaconProxy (not UUPS).

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./IGamePriceOracle.sol";

/// @title SugorokuAMMPool
/// @author Sugoroku Team
/// @notice Constant-product AMM pool for token swaps with restricted access
/// @dev Beacon-proxy-compatible. One instance per game, admin (Registry) grants
///      SWAPPER_ROLE to the per-game GameBoard.
contract SugorokuAMMPool is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Role for admin operations (liquidity, fee config)
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Role for swap operations (game contracts only)
    bytes32 public constant SWAPPER_ROLE = keccak256("SWAPPER_ROLE");

    /// @notice Minimum liquidity locked forever to prevent division by zero
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    /// @notice Maximum fee rate (10% = 1000 basis points)
    uint256 public constant MAX_FEE_RATE = 1000;

    /// @notice Fee denominator for basis points calculation
    uint256 public constant FEE_DENOMINATOR = 10000;

    /// @notice LP token name
    string public constant LP_NAME = "Sugoroku AMM LP Token";

    /// @notice LP token symbol
    string public constant LP_SYMBOL = "SGK-LP";

    /// @notice LP token decimals
    uint8 public constant LP_DECIMALS = 18;

    // ═══════════════════════════════════════════════════════════════════════
    //                           STATE VARIABLES
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Payment token (e.g., stablecoin)
    IERC20 public token0;

    /// @notice Game token (e.g., points token)
    IERC20 public token1;

    /// @notice Reserve of token0 (packed with reserve1 and timestamp)
    uint112 private _reserve0;

    /// @notice Reserve of token1
    uint112 private _reserve1;

    /// @notice Last block timestamp for reserves update
    uint32 private _blockTimestampLast;

    /// @notice Total supply of LP tokens
    uint256 public totalSupply;

    /// @notice LP token balances
    mapping(address => uint256) public balanceOf;

    /// @notice Fee rate in basis points (e.g., 30 = 0.3%)
    uint256 public feeRate;

    /// @notice Treasury address for fee collection
    address public treasury;

    /// @notice Price-history oracle. address(0) disables price recording.
    /// @dev Immutable — set in the implementation's constructor. All per-game
    ///      pools share one beacon implementation, so upgrading the AMM beacon
    ///      wires every pool to the oracle atomically. Re-pointing means
    ///      deploying a new implementation and a beacon upgrade.
    address public immutable priceOracle;

    /// @notice Most recent hour bucket already pushed to the oracle.
    /// @dev Guards lazy record-on-swap so the oracle is hit at most once per
    ///      hour. Monotonic — block.timestamp never decreases. New storage in
    ///      this upgrade; the __gap below is reduced 44 → 43 to absorb it.
    uint32 public lastRecordedHour;

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a swap occurs
    /// @param sender Address initiating the swap
    /// @param to Address receiving the output tokens
    /// @param amount0In Amount of token0 input
    /// @param amount1In Amount of token1 input
    /// @param amount0Out Amount of token0 output
    /// @param amount1Out Amount of token1 output
    /// @param feeAmount Fee amount collected
    /// @param feeToken Address of token used for fee
    event Swap(
        address indexed sender,
        address indexed to,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        uint256 feeAmount,
        address feeToken
    );

    /// @notice Emitted when liquidity is added
    /// @param provider Address providing liquidity
    /// @param amount0 Amount of token0 added
    /// @param amount1 Amount of token1 added
    /// @param liquidity LP tokens minted
    event LiquidityAdded(
        address indexed provider,
        uint256 amount0,
        uint256 amount1,
        uint256 liquidity
    );

    /// @notice Emitted when liquidity is removed
    /// @param provider Address removing liquidity
    /// @param amount0 Amount of token0 removed
    /// @param amount1 Amount of token1 removed
    /// @param liquidity LP tokens burned
    event LiquidityRemoved(
        address indexed provider,
        uint256 amount0,
        uint256 amount1,
        uint256 liquidity
    );

    /// @notice Emitted when reserves are synced
    /// @param reserve0 New reserve of token0
    /// @param reserve1 New reserve of token1
    event Sync(uint112 reserve0, uint112 reserve1);

    /// @notice Emitted when fee rate is updated
    /// @param oldFee Previous fee rate
    /// @param newFee New fee rate
    event FeeRateUpdated(uint256 oldFee, uint256 newFee);

    /// @notice Emitted when treasury is updated
    /// @param oldTreasury Previous treasury address
    /// @param newTreasury New treasury address
    event TreasuryUpdated(address oldTreasury, address newTreasury);

    /// @notice Emitted when swapper authorization changes
    /// @param account Address whose authorization changed
    /// @param authorized Whether the account is now authorized
    event SwapperUpdated(address indexed account, bool authorized);

    /// @notice Emitted on emergency withdrawal
    /// @param token Token withdrawn
    /// @param amount Amount withdrawn
    /// @param to Recipient address
    event EmergencyWithdraw(address indexed token, uint256 amount, address indexed to);

    // ═══════════════════════════════════════════════════════════════════════
    //                           CUSTOM ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Thrown when an address is invalid (zero address)
    error InvalidAddress();

    /// @notice Thrown when an amount is invalid (zero)
    error InvalidAmount();

    /// @notice Thrown when there's insufficient liquidity for operation
    error InsufficientLiquidity();

    /// @notice Thrown when minted liquidity is below minimum
    error InsufficientLiquidityMinted();

    /// @notice Thrown when output amount is below minimum
    error InsufficientOutputAmount();

    /// @notice Thrown when slippage exceeds tolerance
    /// @param expected Minimum expected amount
    /// @param actual Actual amount received
    error SlippageExceeded(uint256 expected, uint256 actual);

    /// @notice Thrown when fee rate exceeds maximum
    /// @param provided Provided fee rate
    /// @param max Maximum allowed fee rate
    error InvalidFeeRate(uint256 provided, uint256 max);

    /// @notice Thrown when token addresses are identical
    error IdenticalAddresses();

    /// @notice Thrown when balance is insufficient
    /// @param required Required balance
    /// @param available Available balance
    error InsufficientBalance(uint256 required, uint256 available);

    /// @notice Thrown when reserve would overflow uint112
    error ReserveOverflow();

    /// @notice Thrown when constant product invariant is violated
    error InvariantViolation();

    // ═══════════════════════════════════════════════════════════════════════
    //                            STORAGE GAP
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Reserved storage space for future upgrades.
    /// @dev Reduced 44 → 43 when `lastRecordedHour` was appended (`priceOracle`
    ///      is immutable and consumes no storage slot).
    uint256[43] private __gap;

    // ═══════════════════════════════════════════════════════════════════════
    //                           CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    /// @param _priceOracle GamePriceOracle address baked into this
    ///        implementation; address(0) disables price recording.
    /// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
    constructor(address _priceOracle) {
        priceOracle = _priceOracle;
        _disableInitializers();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Initialize the AMM pool
    /// @param _token0 Address of payment token (e.g., stablecoin)
    /// @param _token1 Address of game token
    /// @param _treasury Address to receive fees
    /// @param _feeRate Fee rate in basis points (max 1000 = 10%)
    /// @param _admin Admin address with full control
    function initialize(
        address _token0,
        address _token1,
        address _treasury,
        uint256 _feeRate,
        address _admin
    ) external initializer {
        if (
            _token0 == address(0) ||
            _token1 == address(0) ||
            _treasury == address(0) ||
            _admin == address(0)
        ) {
            revert InvalidAddress();
        }
        if (_token0 == _token1) revert IdenticalAddresses();
        if (_feeRate > MAX_FEE_RATE) revert InvalidFeeRate(_feeRate, MAX_FEE_RATE);

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        treasury = _treasury;
        feeRate = _feeRate;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        // SWAPPER_ROLE is NOT granted to admin. Admin grants it to the per-game
        // GameBoard after deploy. DEFAULT_ADMIN_ROLE is sufficient to grant any
        // role under OZ AccessControl.
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Pause all swap operations
    /// @dev Only callable by admin role
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpause swap operations
    /// @dev Only callable by admin role
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Get current reserves and last update timestamp
    /// @return reserve0 Current reserve of token0
    /// @return reserve1 Current reserve of token1
    /// @return blockTimestampLast Timestamp of last reserve update
    function getReserves()
        public
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)
    {
        reserve0 = _reserve0;
        reserve1 = _reserve1;
        blockTimestampLast = _blockTimestampLast;
    }

    /// @notice Calculate equivalent amount of tokenB given amount of tokenA
    /// @dev Used for calculating proportional liquidity additions
    /// @param amountA Amount of token A
    /// @param reserveA Reserve of token A
    /// @param reserveB Reserve of token B
    /// @return amountB Equivalent amount of token B
    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) public pure returns (uint256 amountB) {
        if (amountA == 0) revert InvalidAmount();
        if (reserveA == 0 || reserveB == 0) revert InsufficientLiquidity();
        amountB = (amountA * reserveB) / reserveA;
    }

    /// @notice Calculate output amount for a given input amount
    /// @dev Applies constant product formula with fee deduction
    /// @param amountIn Amount of input token
    /// @param tokenIn Address of input token (must be token0 or token1)
    /// @return amountOut Amount of output token
    /// @return feeAmount Fee amount deducted from input
    function getAmountOut(
        uint256 amountIn,
        address tokenIn
    ) public view returns (uint256 amountOut, uint256 feeAmount) {
        if (amountIn == 0) revert InvalidAmount();

        (uint112 reserve0_, uint112 reserve1_, ) = getReserves();

        uint256 reserveIn;
        uint256 reserveOut;

        if (tokenIn == address(token0)) {
            reserveIn = reserve0_;
            reserveOut = reserve1_;
        } else if (tokenIn == address(token1)) {
            reserveIn = reserve1_;
            reserveOut = reserve0_;
        } else {
            revert InvalidAddress();
        }

        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        // Calculate fee
        feeAmount = (amountIn * feeRate) / FEE_DENOMINATOR;
        uint256 amountInAfterFee = amountIn - feeAmount;

        // Constant product formula: amountOut = (reserveOut * amountInAfterFee) / (reserveIn + amountInAfterFee)
        uint256 numerator = reserveOut * amountInAfterFee;
        uint256 denominator = reserveIn + amountInAfterFee;
        amountOut = numerator / denominator;
    }

    /// @notice Calculate input amount required for a desired output amount
    /// @dev Reverse calculation of constant product formula with fee
    /// @param amountOut Desired amount of output token
    /// @param tokenOut Address of output token (must be token0 or token1)
    /// @return amountIn Required amount of input token
    /// @return feeAmount Fee amount included in input
    function getAmountIn(
        uint256 amountOut,
        address tokenOut
    ) public view returns (uint256 amountIn, uint256 feeAmount) {
        if (amountOut == 0) revert InvalidAmount();

        (uint112 reserve0_, uint112 reserve1_, ) = getReserves();

        uint256 reserveIn;
        uint256 reserveOut;

        if (tokenOut == address(token0)) {
            reserveIn = reserve1_;
            reserveOut = reserve0_;
        } else if (tokenOut == address(token1)) {
            reserveIn = reserve0_;
            reserveOut = reserve1_;
        } else {
            revert InvalidAddress();
        }

        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        if (amountOut >= reserveOut) revert InsufficientLiquidity();

        // Reverse calculation: amountIn = (reserveIn * amountOut) / (reserveOut - amountOut)
        uint256 numerator = reserveIn * amountOut;
        uint256 denominator = reserveOut - amountOut;
        uint256 amountInBeforeFee = (numerator / denominator) + 1; // Round up

        // Add fee: amountIn = amountInBeforeFee * FEE_DENOMINATOR / (FEE_DENOMINATOR - feeRate)
        amountIn = (amountInBeforeFee * FEE_DENOMINATOR) / (FEE_DENOMINATOR - feeRate);
        feeAmount = amountIn - amountInBeforeFee;
    }

    /// @notice Get equivalent token1 amount for given token0 amount (spot price)
    /// @dev Does not include fees, use getAmountOut for actual swap amounts
    /// @param amount0 Amount of token0
    /// @return amount1 Equivalent amount of token1 at current rate
    function getToken0Price(uint256 amount0) external view returns (uint256 amount1) {
        (uint112 reserve0_, uint112 reserve1_, ) = getReserves();
        if (reserve0_ == 0) return 0;
        amount1 = (amount0 * reserve1_) / reserve0_;
    }

    /// @notice Get equivalent token0 amount for given token1 amount (spot price)
    /// @dev Does not include fees, use getAmountOut for actual swap amounts
    /// @param amount1 Amount of token1
    /// @return amount0 Equivalent amount of token0 at current rate
    function getToken1Price(uint256 amount1) external view returns (uint256 amount0) {
        (uint112 reserve0_, uint112 reserve1_, ) = getReserves();
        if (reserve1_ == 0) return 0;
        amount0 = (amount1 * reserve0_) / reserve1_;
    }

    /// @notice Get exchange rate of token1 per token0, scaled by 1e18
    /// @dev Returns how many token1 you get per 1 token0 (scaled)
    /// @return rate Exchange rate scaled by 1e18
    function getExchangeRate() external view returns (uint256 rate) {
        (uint112 reserve0_, uint112 reserve1_, ) = getReserves();
        if (reserve0_ == 0) return 0;
        // Rate = token1 per token0, scaled by 1e18
        rate = (uint256(reserve1_) * 1e18) / reserve0_;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       LIQUIDITY FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Add liquidity to the pool (admin only)
    /// @dev Mints LP tokens proportional to contribution. First deposit uses geometric mean.
    /// @param amount0 Amount of token0 to add
    /// @param amount1 Amount of token1 to add
    /// @param minLiquidity Minimum LP tokens to mint (slippage protection)
    /// @return liquidity Amount of LP tokens minted
    function addLiquidity(
        uint256 amount0,
        uint256 amount1,
        uint256 minLiquidity
    ) external whenNotPaused nonReentrant onlyRole(ADMIN_ROLE) returns (uint256 liquidity) {
        if (amount0 == 0 || amount1 == 0) revert InvalidAmount();

        (uint112 reserve0_, uint112 reserve1_, ) = getReserves();
        uint256 _totalSupply = totalSupply;

        if (_totalSupply == 0) {
            // First deposit - use geometric mean
            liquidity = _sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            // Permanently lock MINIMUM_LIQUIDITY to address(0)
            balanceOf[address(0)] = MINIMUM_LIQUIDITY;
            totalSupply = MINIMUM_LIQUIDITY;
        } else {
            // Calculate liquidity based on existing ratio
            uint256 liquidity0 = (amount0 * _totalSupply) / reserve0_;
            uint256 liquidity1 = (amount1 * _totalSupply) / reserve1_;
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        }

        if (liquidity < minLiquidity) revert InsufficientLiquidityMinted();

        // Transfer tokens from admin to pool
        token0.safeTransferFrom(msg.sender, address(this), amount0);
        token1.safeTransferFrom(msg.sender, address(this), amount1);

        // Mint LP tokens to admin
        balanceOf[msg.sender] += liquidity;
        totalSupply += liquidity;

        // Update reserves
        _update(token0.balanceOf(address(this)), token1.balanceOf(address(this)));

        emit LiquidityAdded(msg.sender, amount0, amount1, liquidity);
    }

    /// @notice Remove liquidity from the pool (admin only)
    /// @dev Burns LP tokens and returns proportional share of reserves
    /// @param liquidity Amount of LP tokens to burn
    /// @param minAmount0 Minimum token0 to receive (slippage protection)
    /// @param minAmount1 Minimum token1 to receive (slippage protection)
    /// @return amount0 Amount of token0 received
    /// @return amount1 Amount of token1 received
    function removeLiquidity(
        uint256 liquidity,
        uint256 minAmount0,
        uint256 minAmount1
    )
        external
        whenNotPaused
        nonReentrant
        onlyRole(ADMIN_ROLE)
        returns (uint256 amount0, uint256 amount1)
    {
        if (liquidity == 0) revert InvalidAmount();
        if (balanceOf[msg.sender] < liquidity) {
            revert InsufficientBalance(liquidity, balanceOf[msg.sender]);
        }

        uint256 _totalSupply = totalSupply;
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));

        // Calculate proportional amounts
        amount0 = (liquidity * balance0) / _totalSupply;
        amount1 = (liquidity * balance1) / _totalSupply;

        if (amount0 < minAmount0 || amount1 < minAmount1) {
            revert InsufficientOutputAmount();
        }

        // Burn LP tokens
        balanceOf[msg.sender] -= liquidity;
        totalSupply -= liquidity;

        // Transfer tokens to admin
        token0.safeTransfer(msg.sender, amount0);
        token1.safeTransfer(msg.sender, amount1);

        // Update reserves
        _update(token0.balanceOf(address(this)), token1.balanceOf(address(this)));

        emit LiquidityRemoved(msg.sender, amount0, amount1, liquidity);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         SWAP FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Swap token0 for token1
    /// @dev Convenience function for token0 → token1 swaps
    /// @param amountIn Amount of token0 to swap
    /// @param minAmountOut Minimum token1 to receive (slippage protection)
    /// @param to Address to receive token1
    /// @return amountOut Actual amount of token1 received
    function swap0For1(
        uint256 amountIn,
        uint256 minAmountOut,
        address to
    ) external whenNotPaused nonReentrant onlyRole(SWAPPER_ROLE) returns (uint256 amountOut) {
        return _swap(amountIn, minAmountOut, address(token0), to);
    }

    /// @notice Swap token1 for token0
    /// @dev Convenience function for token1 → token0 swaps
    /// @param amountIn Amount of token1 to swap
    /// @param minAmountOut Minimum token0 to receive (slippage protection)
    /// @param to Address to receive token0
    /// @return amountOut Actual amount of token0 received
    function swap1For0(
        uint256 amountIn,
        uint256 minAmountOut,
        address to
    ) external whenNotPaused nonReentrant onlyRole(SWAPPER_ROLE) returns (uint256 amountOut) {
        return _swap(amountIn, minAmountOut, address(token1), to);
    }

    /// @notice Generic swap function
    /// @dev Swaps tokenIn for the other token in the pair
    /// @param amountIn Amount of input token
    /// @param minAmountOut Minimum output to receive (slippage protection)
    /// @param tokenIn Address of input token (must be token0 or token1)
    /// @param to Address to receive output tokens
    /// @return amountOut Actual amount received
    function swap(
        uint256 amountIn,
        uint256 minAmountOut,
        address tokenIn,
        address to
    ) external whenNotPaused nonReentrant onlyRole(SWAPPER_ROLE) returns (uint256 amountOut) {
        return _swap(amountIn, minAmountOut, tokenIn, to);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Internal swap implementation
    /// @param amountIn Amount of input token
    /// @param minAmountOut Minimum output (slippage protection)
    /// @param tokenIn Address of input token
    /// @param to Recipient of output tokens
    /// @return amountOut Actual output amount
    function _swap(
        uint256 amountIn,
        uint256 minAmountOut,
        address tokenIn,
        address to
    ) internal returns (uint256 amountOut) {
        if (amountIn == 0) revert InvalidAmount();
        if (to == address(0)) revert InvalidAddress();

        // Calculate output and fee
        (uint256 calculatedOut, uint256 feeAmount) = getAmountOut(amountIn, tokenIn);
        if (calculatedOut < minAmountOut) {
            revert SlippageExceeded(minAmountOut, calculatedOut);
        }

        bool isToken0In = tokenIn == address(token0);

        // Transfer input tokens from sender to this contract
        if (isToken0In) {
            token0.safeTransferFrom(msg.sender, address(this), amountIn);
            if (feeAmount > 0) {
                token0.safeTransfer(treasury, feeAmount);
            }
            token1.safeTransfer(to, calculatedOut);
        } else {
            token1.safeTransferFrom(msg.sender, address(this), amountIn);
            if (feeAmount > 0) {
                token1.safeTransfer(treasury, feeAmount);
            }
            token0.safeTransfer(to, calculatedOut);
        }

        // Update reserves based on actual balances
        _update(token0.balanceOf(address(this)), token1.balanceOf(address(this)));

        // Emit swap event with correct directional amounts
        emit Swap(
            msg.sender,
            to,
            isToken0In ? amountIn : 0,
            isToken0In ? 0 : amountIn,
            isToken0In ? 0 : calculatedOut,
            isToken0In ? calculatedOut : 0,
            feeAmount,
            tokenIn
        );

        amountOut = calculatedOut;
    }

    /// @dev Update reserves and emit Sync event
    /// @param balance0 New balance of token0
    /// @param balance1 New balance of token1
    function _update(uint256 balance0, uint256 balance1) internal {
        if (balance0 > type(uint112).max || balance1 > type(uint112).max) {
            revert ReserveOverflow();
        }
        _reserve0 = uint112(balance0);
        _reserve1 = uint112(balance1);
        _blockTimestampLast = uint32(block.timestamp % 2 ** 32);
        emit Sync(_reserve0, _reserve1);

        _recordPrice();
    }

    /// @dev Lazy price recording: push the post-trade reserves to the price
    ///      oracle once per hourly bucket. The common path (same hour) is two
    ///      warm SLOADs and a comparison; only the first trade of each hour
    ///      pays an SSTORE and the external call. Wrapped in try/catch so a
    ///      faulty, paused, or malicious oracle can never block a swap.
    function _recordPrice() private {
        address oracle = priceOracle;
        if (oracle == address(0)) return;

        uint32 currentHour = uint32(block.timestamp / 3600);
        if (currentHour > lastRecordedHour) {
            // Update the guard before the call so a reverting oracle is not
            // retried within the same hour.
            lastRecordedHour = currentHour;
            // solhint-disable-next-line no-empty-blocks
            try IGamePriceOracle(oracle).record(_reserve0, _reserve1) {} catch {}
        }
    }

    /// @dev Babylonian method for square root calculation
    /// @param y Value to calculate square root of
    /// @return z Square root of y
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
