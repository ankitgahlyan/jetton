//  SPDX-License-Identifier: MIT
//  Copyright © 2025 TON Studio
//TODO:
//const gasForMint: Int = 11050; //anybody can mint(burn if minted) limitedAmount(not fixedAmount once) per id
const gasForBurn: Int = 8000;
const gasForTransfer: Int = 11050;
const minTonsForStorage: Int = ton("0.01"); // This should use https://github.com/tact-lang/tact/issues/2336 in the future
const Basechain: Int = 0;

// This is an approximate value. Real one must be less than this, and it is checked in tests.
const walletStateInitCells: Int = 30;
const walletStateInitBits: Int = 20000;

//const mbrpAmount: Int = ton("1000");
//const closureWait: Int = 86400;
// Declare a compile-time constant upper-bound for our map
//const maxConnections: Int = 200;//contract can send only approx 250 msg once
