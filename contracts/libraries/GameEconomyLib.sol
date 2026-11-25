// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ABOUTME: Extracted bytecode-heavy parts of Registry.deployGame() to keep
// ABOUTME: Registry under the 24KB EVM contract size limit.

import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IGameTokenInit {
    function initialize(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply,
        address admin
    ) external;
}

interface IAmmPoolInit {
    function initialize(
        address _token0,
        address _token1,
        address _treasury,
        uint256 _feeRate,
        address _admin
    ) external;
    function addLiquidity(
        uint256 amount0,
        uint256 amount1,
        uint256 minLiquidity
    ) external returns (uint256 liquidity);
    function removeLiquidity(
        uint256 liquidity,
        uint256 minAmount0,
        uint256 minAmount1
    ) external returns (uint256 amount0, uint256 amount1);
    function swap(
        uint256 amountIn,
        uint256 minAmountOut,
        address tokenIn,
        address to
    ) external returns (uint256 amountOut);
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IGameBoardContribute {
    function contributeLotteryPool(uint256 tilePosition, uint256 amount) external;
}

interface IGameBoardConfig {
    function setFeeConfig(
        uint256 dicePrice,
        uint256 platformFeeRate,
        uint256 leaderboardFeeRate,
        uint256 ammPoolFeeRate,
        uint256 goalFeeRate
    ) external;
    function setAllLotteryConfigs(uint16[12] calldata flat) external;
}

/// @notice Per-game economic rules applied at deploy time. Defined here (not in
///         Registry) so deployGame can pass calldata directly to the library
///         applyGameRules() helper without a struct-type mismatch.
struct GameRules {
    uint256 dicePrice;
    uint256 platformFeeRate; // basis points
    uint256 leaderboardFeeRate; // basis points
    uint256 ammPoolFeeRate; // basis points; sum of the four fee rates must == 10000
    uint16[12] lotteryRates; // [b.win, b.payout, b.loss, s..., g..., j...] in bp; each <= 10000
    uint256 goalFeeRate; // basis points; USDC goal treasury share (V9 boards)
}

/**
 * @title GameEconomyLib
 * @notice Library for deploying a per-game token + AMM pool + seeding liquidity.
 * @dev External library functions are executed via DELEGATECALL in the caller's
 *      context (Registry), so msg.sender is preserved from the original caller.
 *      Registry MUST have the initialSupply of gameToken before calling
 *      seedLiquidity (the BeaconProxy constructor mints to address(this) which
 *      during delegatecall = Registry).
 */
interface IGameBoardInit {
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
}

library GameEconomyLib {
    using SafeERC20 for IERC20;

    error FeeOnTransferDetected();
    error ProxyDeploymentFailed();
    error LengthMismatch();
    error InsufficientSwapOutput(uint256 need, uint256 got);
    error PoolUninitialized();
    error ZeroAmount();

    /** @notice Swap a caller-funded USDC amount and credit every received token to one tile. */
    function fundLotteryPool(
        address usdcFrom,
        address usdcToken,
        address pool,
        address gameToken,
        address gameBoard,
        uint256 tilePosition,
        uint256 usdcAmount,
        uint256 minTokensOut
    ) external returns (uint256 tokensOut) {
        if (usdcAmount == 0 || minTokensOut == 0 || tilePosition == 0) revert ZeroAmount();
        uint256 usdcBefore = IERC20(usdcToken).balanceOf(address(this));
        IERC20(usdcToken).safeTransferFrom(usdcFrom, address(this), usdcAmount);
        if (IERC20(usdcToken).balanceOf(address(this)) - usdcBefore != usdcAmount) {
            revert FeeOnTransferDetected();
        }
        IERC20(usdcToken).forceApprove(pool, usdcAmount);
        uint256 tokensBefore = IERC20(gameToken).balanceOf(gameBoard);
        tokensOut = IAmmPoolInit(pool).swap(usdcAmount, minTokensOut, usdcToken, gameBoard);
        if (IERC20(gameToken).balanceOf(gameBoard) - tokensBefore != tokensOut) {
            revert FeeOnTransferDetected();
        }
        // No dice, purchase fees, or unallocated token cushion: all output backs this tile.
        IGameBoardContribute(gameBoard).contributeLotteryPool(tilePosition, tokensOut);
        IERC20(usdcToken).forceApprove(pool, 0);
    }

    /**
     * @notice Pull `amountIn` game tokens from `seller`, swap them for USDC on `pool` and
     *         send the USDC to `seller`. Sell side only; `minUsdcOut` must be non-zero.
     * @dev Runs by DELEGATECALL in the Registry, whose SWAPPER_ROLE performs the swap.
     */
    function sellTokens(
        address seller,
        address gameToken,
        address pool,
        uint256 amountIn,
        uint256 minUsdcOut
    ) external returns (uint256 usdcOut) {
        if (amountIn == 0 || minUsdcOut == 0) revert ZeroAmount();
        uint256 before = IERC20(gameToken).balanceOf(address(this));
        IERC20(gameToken).safeTransferFrom(seller, address(this), amountIn);
        if (IERC20(gameToken).balanceOf(address(this)) - before != amountIn) {
            revert FeeOnTransferDetected();
        }
        IERC20(gameToken).forceApprove(pool, amountIn);
        usdcOut = IAmmPoolInit(pool).swap(amountIn, minUsdcOut, gameToken, seller);
        IERC20(gameToken).forceApprove(pool, 0);
    }

    /**
     * @notice Deploy a GameBoard BeaconProxy with init data encoded.
     * @dev Extracted from Registry to save bytecode. Called via delegatecall
     *      so `address(this)` inside is Registry's address.
     */
    struct GameBoardInitParams {
        address beacon;
        uint256 gameId;
        uint256 boardType;
        uint256 templateVersion;
        bytes32 boardSeed;
        address creator;
        address playerProgressSBT;
        address usdcToken;
        address perGameAmmPool;
        bytes templateData;
    }

    function deployGameBoardProxy(
        GameBoardInitParams calldata p
    ) external returns (address proxyAddress) {
        bytes memory initData = abi.encodeCall(
            IGameBoardInit.initialize,
            (
                p.gameId,
                p.boardType,
                p.templateVersion,
                p.boardSeed,
                address(this),
                p.playerProgressSBT,
                p.usdcToken,
                p.perGameAmmPool,
                p.templateData
            )
        );
        bytes32 salt = keccak256(
            abi.encodePacked(
                p.gameId,
                p.boardType,
                p.templateVersion,
                p.boardSeed,
                p.creator,
                "BeaconProxy"
            )
        );
        proxyAddress = address(new BeaconProxy{ salt: salt }(p.beacon, initData));
        if (proxyAddress == address(0)) revert ProxyDeploymentFailed();
    }

    /**
     * @notice Deploy the per-game GameToken and AMM pool as BeaconProxies.
     *         Registry receives the full token initialSupply and holds
     *         DEFAULT_ADMIN_ROLE on the pool.
     */
    function deployTokenAndPool(
        address gameTokenBeacon,
        address ammPoolBeacon,
        address usdcToken,
        address treasury,
        string calldata tokenName,
        string calldata tokenSymbol,
        uint256 tokenSupply
    ) external returns (address gameToken, address pool) {
        gameToken = address(
            new BeaconProxy(
                gameTokenBeacon,
                abi.encodeCall(
                    IGameTokenInit.initialize,
                    (tokenName, tokenSymbol, tokenSupply, address(this))
                )
            )
        );

        pool = address(
            new BeaconProxy(
                ammPoolBeacon,
                abi.encodeCall(
                    IAmmPoolInit.initialize,
                    (usdcToken, gameToken, treasury, 30, address(this))
                )
            )
        );
    }

    /**
     * @notice Pull deploy-time USDC from `usdcFrom`, seed the pool with the
     *         corresponding token amount, keep LP on the Registry, and transfer
     *         unseeded tokens to `tokenRecipient`.
     * @dev FOT guard: reverts if the USDC balance delta doesn't match the
     *      requested amount (detects fee-on-transfer or hook-capable tokens).
     */
    function seedLiquidity(
        address pool,
        address gameToken,
        address usdcToken,
        address usdcFrom,
        address tokenRecipient,
        uint256 initialUsdcLiquidity,
        uint256 fullUsdcLiquidity,
        uint256 tokenSupply,
        uint256 lotteryReserve
    ) external {
        // Keep lottery seed tokens out of the AMM price basis so the deploy-time
        // price equals later Admin add-liquidity at the same ratio. The reserve
        // stays with tokenRecipient (engine) and is distributed via seedLotteryPool.
        uint256 ammBasis = tokenSupply - lotteryReserve;
        uint256 initialTokenLiquidity = (ammBasis * initialUsdcLiquidity) / fullUsdcLiquidity;
        if (initialTokenLiquidity == 0) revert ZeroAmount();

        uint256 usdcBefore = IERC20(usdcToken).balanceOf(address(this));
        IERC20(usdcToken).safeTransferFrom(usdcFrom, address(this), initialUsdcLiquidity);
        if (IERC20(usdcToken).balanceOf(address(this)) - usdcBefore != initialUsdcLiquidity) {
            revert FeeOnTransferDetected();
        }
        IERC20(usdcToken).forceApprove(pool, initialUsdcLiquidity);
        IERC20(gameToken).forceApprove(pool, initialTokenLiquidity);
        IAmmPoolInit(pool).addLiquidity(initialUsdcLiquidity, initialTokenLiquidity, 0);

        uint256 unseededTokens = tokenSupply - initialTokenLiquidity;
        if (unseededTokens > 0) {
            IERC20(gameToken).safeTransfer(tokenRecipient, unseededTokens);
        }
    }

    /**
     * @notice Seed lottery pools by swapping USDC → per-game token and
     *         contributing the output to each specified tile's pool.
     *
     * @dev Caller (engine/admin) supplies USDC; tokens from the swap go
     *      directly to the GameBoard (no intermediate holder). The script
     *      should pre-quote with `AMMPool.getAmountIn(totalTokens, gameToken)`
     *      and add a small buffer for slippage.
     *
     * @param usdcFrom Who to pull USDC from (pass msg.sender via delegatecall).
     * @param usdcToken USDC address.
     * @param pool Per-game AMM pool.
     * @param gameToken Per-game token (for contributeLotteryPool accounting).
     * @param gameBoard Per-game GameBoard (swap output destination + pool tracker).
     * @param usdcAmount USDC to swap (pre-approved by usdcFrom to Registry).
     * @param positions Lottery tile positions to seed.
     * @param amounts Per-tile game-token amounts. sum(amounts) must be <= swap output.
     */
    function seedLotteries(
        address usdcFrom,
        address usdcToken,
        address pool,
        address gameToken,
        address gameBoard,
        uint256 usdcAmount,
        uint256[] calldata positions,
        uint256[] calldata amounts
    ) external {
        if (positions.length != amounts.length) revert LengthMismatch();

        // 1. Pull USDC from caller and approve pool.
        IERC20(usdcToken).safeTransferFrom(usdcFrom, address(this), usdcAmount);
        IERC20(usdcToken).forceApprove(pool, usdcAmount);

        // 2. Swap USDC → gameToken, output goes directly to the GameBoard.
        uint256 tokensOut = IAmmPoolInit(pool).swap(
            usdcAmount,
            0, // minAmountOut: caller-side validation via amounts[] check below
            usdcToken,
            gameBoard
        );

        // 3. Verify swap produced enough tokens for the requested distribution.
        uint256 totalRequested;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalRequested += amounts[i];
        }
        if (tokensOut < totalRequested) {
            revert InsufficientSwapOutput(totalRequested, tokensOut);
        }

        // 4. Record each tile's contribution in GameBoard's pool accounting.
        //    Excess tokens (tokensOut > totalRequested) stay as an unaccounted
        //    cushion on GameBoard — harmless; backs future exits.
        //
        //    gameToken is unused directly in this loop but kept in the signature
        //    so future extensions (e.g., return-excess) have it available.
        gameToken;
        for (uint256 i = 0; i < positions.length; i++) {
            IGameBoardContribute(gameBoard).contributeLotteryPool(positions[i], amounts[i]);
        }
    }

    /**
     * @notice Top up a per-game AMM pool with caller-supplied game tokens paired
     *         1:1 (by value) against caller-supplied USDC. Preserves price.
     *
     * @dev Flow:
     *   1. Read current reserves. token0 = USDC, token1 = gameToken
     *      (initialize order in deployTokenAndPool).
     *   2. Quote tokenAmount = usdcAmount × reserve1 / reserve0.
     *   3. Pull usdcAmount and tokenAmount from caller.
     *   4. Approve + call pool.addLiquidity.
     *   5. Keep the minted LP on Registry for later admin withdrawal.
     *
     * @param pool Per-game AMM pool.
     * @param gameToken Per-game ERC-20.
     * @param usdcToken USDC address.
     * @param tokenFrom Caller supplying game tokens (pass msg.sender).
     * @param usdcFrom Caller supplying USDC (pass msg.sender).
     * @param usdcAmount USDC to deposit.
     * @return tokenAmount Game tokens deposited into the pool.
     * @return lpMinted LP tokens minted to Registry.
     */
    function addLiquidity(
        address pool,
        address gameToken,
        address usdcToken,
        address tokenFrom,
        address usdcFrom,
        uint256 usdcAmount
    ) external returns (uint256 tokenAmount, uint256 lpMinted) {
        if (usdcAmount == 0) revert ZeroAmount();

        (uint112 reserve0, uint112 reserve1, ) = IAmmPoolInit(pool).getReserves();
        if (reserve0 == 0 || reserve1 == 0) revert PoolUninitialized();

        tokenAmount = (usdcAmount * uint256(reserve1)) / uint256(reserve0);
        if (tokenAmount == 0) revert ZeroAmount();

        IERC20(usdcToken).safeTransferFrom(usdcFrom, address(this), usdcAmount);
        IERC20(gameToken).safeTransferFrom(tokenFrom, address(this), tokenAmount);

        IERC20(usdcToken).forceApprove(pool, usdcAmount);
        IERC20(gameToken).forceApprove(pool, tokenAmount);

        lpMinted = IAmmPoolInit(pool).addLiquidity(usdcAmount, tokenAmount, 0);
    }

    /**
     * @notice Apply per-game rules (fee config + lottery configs) to the GameBoard.
     * @dev Called once at deploy from Registry.deployGame. Lifted into the
     *      library to free stack space in deployGame (stack-too-deep otherwise).
     */
    function applyGameRules(address gameBoard, GameRules calldata rules) external {
        IGameBoardConfig(gameBoard).setFeeConfig(
            rules.dicePrice,
            rules.platformFeeRate,
            rules.leaderboardFeeRate,
            rules.ammPoolFeeRate,
            rules.goalFeeRate
        );
        IGameBoardConfig(gameBoard).setAllLotteryConfigs(rules.lotteryRates);
    }
}
