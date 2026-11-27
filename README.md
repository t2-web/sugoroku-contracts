# SUGOROKU

A fully on-chain dice board game built on **BNB Smart Chain (BSC)**.

Players buy dice with USDC, roll across a hex board, battle monsters on lottery tiles and cash out in USDC. Every roll, prize pool and payout is a BSC transaction. There is no game server.

- Website: https://sugorok.planz.tech/
- Player guide (6 languages): https://sugorok.planz.tech/guide/
- Fairness page: https://sugorok.planz.tech/fairness
- X: https://x.com/SUGOROKU_Crypto

This repository holds the source of the contracts running on BNB Smart Chain Mainnet, and the libraries and interfaces they compile with. Each file is the exact source of the deployed bytecode.

## Technology Stack

- **Blockchain**: BNB Smart Chain (BSC)
- **Smart Contracts**: Solidity 0.8.28, OpenZeppelin Contracts 5.4.0 (UUPS and beacon proxies)
- **Development**: Hardhat
- **Configuration**: see `bnbconfig.json` (primary chain: BSC Mainnet, chain ID 56)

## Supported Networks

- **BNB Smart Chain Mainnet** (Chain ID: 56): production

## Contract Addresses

### Player-facing contracts (BNB Mainnet)

| Contract | Address | Type | Source |
|---|---|---|---|
| GameRegistry | 0x6C7e284BACfD075afA6211ae9FCAef57E764A9eb | UUPS proxy | `contracts/SugorokuGameRegistry.sol` |
| GameBoard (Goblin Arena) | 0x1F65f2E6B5dBb787eC4b2c11322c88bAB8B65e8A | Beacon proxy | `contracts/SugorokuGameBoard.sol` |
| GameBoard (Slime Arena) | 0x58122163D9a03754ffea62db2aD70E3Fbb372f91 | Beacon proxy | `contracts/SugorokuGameBoard.sol` |
| GameBoard (Orc Arena) | 0xDaBb5ad69F6645A2EfcEf125165BbCbfddb70ECa | Beacon proxy | `contracts/SugorokuGameBoard.sol` |
| GameBoard (Dragon Arena) | 0x0c9377e5450647A32067e072Bc8270c1cD6E3b47 | Beacon proxy | `contracts/SugorokuGameBoard.sol` |
| DiceNFT | 0x4110022035579e6D2905010948236343A4335aAE | UUPS proxy | `contracts/DiceNFT.sol` |
| DiceNFT Redeemer | 0x6d8D7D9d85224Bcd9eb5dfEd6fA5edA85D64A259 | UUPS proxy | `contracts/DiceNFTRedeemer.sol` |
| GenesisAdventurer | 0x1C312e8F1018e55dc6de6362133e799025697619 | UUPS proxy | `contracts/GenesisAdventurer.sol` |
| SummonDiceClaim | 0x5956FD764c29f570BA9Cba183cB0133e2deef177 | UUPS proxy | `contracts/SummonDiceClaim.sol` |
| PlayerProgressSBT | 0x39c4A8ccE648A37cA0BB2c544bD86A1E5484fe20 | UUPS proxy | `contracts/PlayerProgressSBTUpgradeable.sol` |
| GoalNftPrizes | 0xe9144e53811118da7003436351a4f57BFf59DE4E | UUPS proxy | `contracts/GoalNftPrizes.sol` |
| GamePriceOracle | 0xE9bfe8529f48C970903411Fe38585cA4Fae455E5 | UUPS proxy | `contracts/GamePriceOracle.sol` |

### Per-arena token and pool (BNB Mainnet)

Each arena has its own in-game token and AMM pool, deployed by the GameRegistry as beacon proxies.

| Arena | GameToken | AMM pool |
|---|---|---|
| Goblin | 0x7b641a0176A31dBA638d103Eb4E861c13F14CF0D | 0x1519f2bB16D9bc858a261724C24004ab4179E8B6 |
| Slime | 0x04cd2b32C37Ccf342C2EAa2e1B7080F8b0Cbf366 | 0xe2901c6906de7f95f13c5Cf0B575d17F0FA7711A |
| Orc | 0xbA2a5f5DA777b85a106A9fAd35E28b03aA024E3C | 0x67CDE64D251647B90f93f85a035919B4b73Ed7B2 |
| Dragon | 0x762a1620673FF921C633ff0154ef92fC52Fafc2a | 0x42698dE22Cc5A4E1c78CB671535Ab31409DA5782 |

### Implementations, beacons and libraries (BNB Mainnet)

| Contract | Address | Source |
|---|---|---|
| SugorokuGameRegistry (implementation) | 0xc2526F217D9B737071B9DD6D0ab01F04c65eA135 | `contracts/SugorokuGameRegistry.sol` |
| GameEconomyLib (linked by the registry) | 0xC1cDB6c96818e92d51860aAEE64f97ee5a765495 | `contracts/libraries/GameEconomyLib.sol` |
| SugorokuGameBoard (implementation) | 0x5177196bDBA96B028a60202b13D786120De4B9a4 | `contracts/SugorokuGameBoard.sol` |
| LeaderboardLib (linked by the board) | 0xCDAdf038FcDF9D5B1E996F4b0b52e446A2C40428 | `contracts/libraries/LeaderboardLib.sol` |
| GoalRewardLib (linked by the board) | 0x8F2D5C256A043764288fC6a48E4C605c5053736C | `contracts/libraries/GoalRewardLib.sol` |
| GameBoard beacon | 0xaD1667C535D8A1964CFE098CcD3350d402068D9E | OpenZeppelin `UpgradeableBeacon` |
| GameToken (implementation) | 0x4494ADA0435E7b6DcB8276C331dDB4742EFEF0AC | `contracts/GameToken.sol` |
| GameToken beacon | 0x19E66E063D6C11521e35F4C2ECc49196077c2b63 | OpenZeppelin `UpgradeableBeacon` |
| SugorokuAMMPool (implementation) | 0x8a92c6c47fcFf281FB836AD7bf55F30E5B53C482 | `contracts/SugorokuAMMPool.sol` |
| AMM pool beacon | 0xcb9519666d87afa688039B3850Be2fd618A1Fd43 | OpenZeppelin `UpgradeableBeacon` |
| DiceNFT (implementation) | 0xa628AC1f86918DC865821d19f875328A4c00354d | `contracts/DiceNFT.sol` |
| DiceNFTRedeemer (implementation) | 0x234e14266089c2688E5de3384886125908cc11A7 | `contracts/DiceNFTRedeemer.sol` |
| GenesisAdventurer (implementation) | 0x11D74ed6543C75C1ff01729ADcd586B7E6B8D2D8 | `contracts/GenesisAdventurer.sol` |
| SummonDiceClaim (implementation) | 0x43045F7deB89C38733BDFD5AA84c9a992541612E | `contracts/SummonDiceClaim.sol` |
| PlayerProgressSBTUpgradeable (implementation) | 0xC04bB0e52Ae5864741745De02EE4658f7680cC88 | `contracts/PlayerProgressSBTUpgradeable.sol` |
| GoalNftPrizes (implementation) | 0x9714b725ca5B60cB3274e6cfdf6B59BBC071E9D0 | `contracts/GoalNftPrizes.sol` |
| GamePriceOracle (implementation) | 0x87b0fA63424dF833B78A1C61FDF4ec55A50Af1C2 | `contracts/GamePriceOracle.sol` |

SUGOROKU has no token for sale. Each arena has its own in-game token, used inside the arena's pool; players never need to hold it, and they deposit and withdraw only USDC.

## Features

- Fully on-chain game state on BSC: dice, moves, battles, prize pools and payouts are all contract calls
- Two-transaction moves: each roll is settled by the hash of a block that does not exist yet when the player rolls
- Four arenas with different dice prices (0.2, 1 and 5 USDC) and board sizes (26, 51 and 101 tiles)
- Lottery tiles and a jackpot with on-chain prize pools; a Goal Treasury paid out in USDC
- Monthly ranking seasons in the Dragon Arena, settled on-chain in USDC
- Free dice through soulbound Dice NFTs and the Genesis Summon free mint
- A keeper that finishes stalled rolls and claims on behalf of players, never to its own wallet

## Build

Requires Node.js 18 or later and pnpm.

```bash
pnpm install
pnpm compile
```

Compiler: solc 0.8.28, `viaIR`, EVM `cancun`, optimizer 200 runs. `SugorokuGameBoard.sol` uses optimizer 1 run, stripped revert strings and no metadata hash, to stay under the contract size limit. The settings are in `hardhat.config.js`.

## License

MIT. See `LICENSE`.
