// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ABOUTME: Minimal interface for the game-token price-history oracle.
// ABOUTME: Imported by SugorokuAMMPool to push one observation per hourly bucket.

/// @title IGamePriceOracle
/// @author Sugoroku Team
/// @notice Interface an AMM pool uses to record its price into the oracle.
/// @dev The oracle keys observations by `msg.sender` (the calling pool), so no
///      pool argument is needed and the call is safely permissionless.
interface IGamePriceOracle {
    /// @notice Record a price observation for the calling pool.
    /// @dev At most one observation is stored per pool per hourly bucket; calls
    ///      within an already-recorded bucket are no-ops.
    /// @param reserve0 Pool reserve of token0 (payment token) at record time.
    /// @param reserve1 Pool reserve of token1 (game token) at record time.
    function record(uint112 reserve0, uint112 reserve1) external;
}
