// SPDX-License-Identifier: MIT
// ABOUTME: Draws the goal reward (a share of the USDC goal treasury, or an NFT prize) and stores the
// ABOUTME: goal odds table. Linked and DELEGATECALLed so this bytecode lives outside SugorokuGameBoard.
pragma solidity ^0.8.28;

import { SugorokuGameBoard } from "../SugorokuGameBoard.sol";

/// @notice The shared NFT prize pool a board reserves goal prizes from (GoalNftPrizes).
interface IGoalNftPrizes {
    /// @return token Prize NFT contract, or address(0) when no prize could be reserved
    function reserve(
        address player,
        uint256 random
    ) external returns (address token, uint256 tokenId);

    function deliver(address player) external;

    function isBoard(address board) external view returns (bool);
}

/**
 * @title GoalRewardLib
 * @notice The goal reward of SugorokuGameBoard (V13). Without an odds table the board keeps the
 *         V7 draw: a uniform percentage within the payout range. With a table, 51 weighted
 *         outcomes: 1% to 50% of the USDC goal treasury, or one NFT from the prize pool.
 * @dev `external` on purpose: an `internal` library function is inlined into the board and would
 *      free no bytecode. The board's storage is reached through fixed slots, pinned by
 *      test/GoalPayoutStorage.test.ts:
 *        slot 44: goalPayoutMinPct (byte 0), goalPayoutMaxPct (byte 1)
 *        slot 45: goalTreasuryUsdc
 *        slots 52..55: goalOdds, read as 64 uint16 entries: entry e sits in slot 52 + e / 16 at
 *          bit 16 * (e % 16).
 *          entry 0: 1 while a table is set, 0 otherwise (the uniform range then applies)
 *          entries 1..51: running totals of the weights, in 0.01%: entry e is the chance of
 *            1%..e% together for e <= 50, and entry 51 (all outcomes, with the NFT) is 10000
 *          bits 64..223 of slot 55 (entries 52..61): the GoalNftPrizes contract
 *        Storing running totals lets a draw skip a whole slot after one comparison with its
 *        last entry. It reads slot 52 first (the flag and 1..15%) and further slots only as
 *        far as its ticket goes; slot 55 holds the NFT and the prize contract together.
 *        setGoalOdds takes plain weights and emits them in GoalOddsChanged.
 *      A won NFT is not sent here. The prize contract reserves it, and the board stores that
 *      contract's address in the player's flags slot (Player slot 6, bytes 2..21, beside `active`
 *      and `roundCompleted`). The board's exit sends `deliver` to that address. Keeping the
 *      address per player means a later change of the board's prize contract cannot strand
 *      a reservation, and the flag costs no new slot.
 */
library GoalRewardLib {
    uint256 private constant GOAL_RANGE_SLOT = 44;
    uint256 private constant GOAL_TREASURY_USDC_SLOT = 45;
    uint256 private constant GOAL_ODDS_SLOT = 52;
    /// @dev Bit offset of the prize contract in the last odds slot (after entries 48..51)
    uint256 private constant PRIZE_SHIFT = 64;
    /// @dev Player struct member slot holding active (byte 0), roundCompleted (byte 1) and the prize (bytes 2..21)
    uint256 private constant PLAYER_FLAGS_OFFSET = 6;
    uint256 private constant ROUND_COMPLETED_BIT = 1 << 8;

    /// @dev Same as SugorokuGameBoard: the keeper may force the exit 5 minutes after the goal.
    uint256 private constant CLAIM_GRACE_PERIOD = 5 minutes;

    /// @dev GOAL is the board's V7 domain, so a board without a table draws exactly as V12 did.
    uint256 private constant GOAL_RANDOM_DOMAIN = 4;
    uint256 private constant PRIZE_RANDOM_DOMAIN = 5;
    uint256 private constant REDRAW_RANDOM_DOMAIN = 6;

    uint256 private constant ODDS_TOTAL = 10000;
    /// @dev Entries 1..50 are percentages; entry 51 is the NFT.
    uint256 private constant MAX_PERCENT_ENTRY = 50;
    uint256 private constant NFT_ENTRY = 51;
    uint256 private constant ODDS_ENTRIES = 64;

    // Same signatures as SugorokuGameBoard's, so logs and reverts decode against its ABI.
    event GoalBonusAwarded(address indexed player, uint8 pct, uint256 usdcAmount);
    event GoalPayoutRangeUsed(address indexed player, uint8 minPct, uint8 maxPct);
    event RoundCompleted(address indexed player, uint256 roundNumber, uint256 totalSgpEarned);
    event GoalNftAwarded(address indexed player, address indexed token, uint256 tokenId);
    event GoalOddsChanged(uint256[4] odds, address prize);
    error InvalidGoalOdds();

    /**
     * @notice Marks the round complete and draws the goal reward, held until the player exits
     * @dev The board calls this only on the first completion of an entry. The pct of an NFT
     *      win is 0 in GoalBonusAwarded, and GoalNftAwarded names the NFT.
     */
    function completeRound(
        SugorokuGameBoard.Player storage p,
        address player,
        bytes32 entropy,
        uint256 effectIndex
    ) external {
        uint256 flagsSlot;
        assembly ("memory-safe") {
            flagsSlot := add(p.slot, PLAYER_FLAGS_OFFSET)
        }
        uint256 flags = _load(flagsSlot) | ROUND_COMPLETED_BIT;
        p.claimDeadline = block.timestamp + CLAIM_GRACE_PERIOD;

        uint256 random = uint256(
            keccak256(abi.encodePacked(entropy, GOAL_RANDOM_DOMAIN, effectIndex, uint256(0)))
        );
        uint256 first = _load(GOAL_ODDS_SLOT);
        uint256 pct;
        if (_entry(first, 0) == 0) {
            // No odds table: the V7 uniform draw within the payout range (1-50% while unset).
            uint256 range = _load(GOAL_RANGE_SLOT);
            uint256 minPct = range & 0xff;
            uint256 maxPct = (range >> 8) & 0xff;
            if (maxPct == 0) (minPct, maxPct) = (1, 50);
            pct = (random % (maxPct - minPct + 1)) + minPct;
            emit GoalPayoutRangeUsed(player, uint8(minPct), uint8(maxPct));
        } else {
            pct = _draw(first, random % ODDS_TOTAL, NFT_ENTRY);
            if (pct == NFT_ENTRY) {
                uint256 last = _load(GOAL_ODDS_SLOT + 3);
                address prize = address(uint160(last >> PRIZE_SHIFT));
                (address token, uint256 tokenId) = IGoalNftPrizes(prize).reserve(
                    player,
                    uint256(keccak256(abi.encodePacked(random, PRIZE_RANDOM_DOMAIN)))
                );
                if (token != address(0)) {
                    pct = 0;
                    flags |= uint256(uint160(prize)) << 16;
                    emit GoalNftAwarded(player, token, tokenId);
                } else {
                    // Nothing could be reserved: draw again among the percentages only,
                    // whose weights sum to the running total at 50%.
                    uint256 redraw = uint256(
                        keccak256(abi.encodePacked(random, REDRAW_RANDOM_DOMAIN))
                    );
                    pct = _draw(first, redraw % _entry(last, MAX_PERCENT_ENTRY), MAX_PERCENT_ENTRY);
                }
            }
        }
        _store(flagsSlot, flags);

        uint256 bonus;
        if (pct != 0) {
            uint256 goalPool = _load(GOAL_TREASURY_USDC_SLOT);
            bonus = (goalPool * pct) / 100;
            _store(GOAL_TREASURY_USDC_SLOT, goalPool - bonus);
            p.goalUsdcPending += bonus;
        }
        emit GoalBonusAwarded(player, uint8(pct), bonus);
        emit RoundCompleted(player, 1, p.totalSgpEarned);
    }

    /**
     * @notice Stores the odds table and the NFT prize contract. All-zero odds remove the table,
     *         so the board draws uniformly within its payout range again.
     * @param odds Plain weights packed in the same entries (e% at entry e, the NFT at 51);
     *        entry 0 and entries 52..63 must be 0. Stored as running totals, with the flag
     *        and the prize contract.
     * @param prize GoalNftPrizes contract; required when the NFT weight is not 0
     */
    function setGoalOdds(uint256[4] calldata odds, address prize) external {
        uint256[4] memory stored;
        uint256 total;
        for (uint256 e; e < ODDS_ENTRIES; ++e) {
            uint256 weight = _entry(odds[e / 16], e);
            if ((e == 0 || e > NFT_ENTRY) && weight != 0) revert InvalidGoalOdds();
            total += weight;
            // Each running total is at most 10000 once the sum is checked below.
            if (e != 0 && e <= NFT_ENTRY) stored[e / 16] |= (total & 0xffff) << (16 * (e % 16));
        }
        uint256 nftWeight = _entry(odds[3], NFT_ENTRY);
        // A table sums to 100% and keeps a percentage outcome for the redraw; an NFT weight
        // needs a prize contract.
        if (
            (total != 0 && total != ODDS_TOTAL) ||
            nftWeight == ODDS_TOTAL ||
            (nftWeight != 0 && prize == address(0))
        ) revert InvalidGoalOdds();
        // Every goal that draws the NFT calls the prize contract, so a wrong address would make
        // those moves revert, and a pool that does not list this board could never stock it.
        // V14 (#767): it must list this board (V13 only probed totalStock, which any pool answers).
        if (prize != address(0) && !IGoalNftPrizes(prize).isBoard(address(this))) {
            revert InvalidGoalOdds();
        }

        if (total == 0) stored = [uint256(0), 0, 0, 0];
        _store(GOAL_ODDS_SLOT, stored[0] | (total == 0 ? 0 : 1));
        _store(GOAL_ODDS_SLOT + 1, stored[1]);
        _store(GOAL_ODDS_SLOT + 2, stored[2]);
        _store(GOAL_ODDS_SLOT + 3, stored[3] | (uint256(uint160(prize)) << PRIZE_SHIFT));
        emit GoalOddsChanged(odds, prize);
    }

    /**
     * @dev First entry in 1..`last` whose running total exceeds `ticket` (which is below the
     *      running total at `last`). A slot whose last relevant entry does not exceed the
     *      ticket is skipped without a scan. `first` is slot 52, already loaded.
     */
    function _draw(uint256 first, uint256 ticket, uint256 last) private view returns (uint256) {
        uint256 word = first;
        unchecked {
            for (uint256 k; k < 4; ++k) {
                if (k != 0) word = _load(GOAL_ODDS_SLOT + k);
                uint256 top = k * 16 + 15 < last ? k * 16 + 15 : last;
                if (ticket < _entry(word, top)) {
                    for (uint256 e = k == 0 ? 1 : k * 16; ; ++e) {
                        if (ticket < _entry(word, e)) return e;
                    }
                }
            }
        }
        // Unreachable: setGoalOdds only stores tables whose running total ends at ODDS_TOTAL.
        revert InvalidGoalOdds();
    }

    function _entry(uint256 word, uint256 e) private pure returns (uint256) {
        unchecked {
            return (word >> (16 * (e % 16))) & 0xffff;
        }
    }

    function _load(uint256 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := sload(slot)
        }
    }

    function _store(uint256 slot, uint256 value) private {
        assembly ("memory-safe") {
            sstore(slot, value)
        }
    }
}
