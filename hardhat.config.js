// Compiler settings used for the contracts deployed on BNB Smart Chain.
// SugorokuGameBoard is built with its own size-oriented settings (runs: 1, stripped revert strings, no metadata hash).
const settings = {
  optimizer: { enabled: true, runs: 200 },
  evmVersion: "cancun",
  viaIR: true,
};

/** @type {import("hardhat/config").HardhatUserConfig} */
module.exports = {
  solidity: {
    compilers: [{ version: "0.8.28", settings }],
    overrides: {
      "contracts/SugorokuGameBoard.sol": {
        version: "0.8.28",
        settings: {
          ...settings,
          optimizer: { enabled: true, runs: 1 },
          debug: { revertStrings: "strip" },
          metadata: { bytecodeHash: "none" },
        },
      },
    },
  },
};
