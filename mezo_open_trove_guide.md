# Opening a Trove on Mezo Testnet

## Overview

This guide explains how to programmatically open a trove (CDP/loan position) on Mezo's MUSD protocol. Mezo is a Liquity fork that uses BTC as collateral instead of ETH.

---

## Quick Answers

### 1. Does Mezo's openTrove use msg.value or ERC-20 approve + transferFrom?

✅ **It uses `msg.value`** — exactly like standard Liquity.

From the source code at `github.com/mezo-org/musd/blob/main/solidity/contracts/BorrowerOperations.sol`:

```solidity
function openTrove(
    uint256 _debtAmount,
    address _upperHint,
    address _lowerHint
) external payable override {
    _openTrove(msg.sender, msg.sender, _debtAmount, _upperHint, _lowerHint);
}
```

**This means:** Even though Mezo has a BTC "token" at `0x7b7C000000000000000000000000000000000000`, you **do NOT need to `approve()` it**. You send native BTC directly via `msg.value` when calling `openTrove`.

---

### 2. What is the exact function signature?

```solidity
function openTrove(
    uint256 _debtAmount,    // Amount of MUSD to borrow
    address _upperHint,      // Hint for sorted trove insertion
    address _lowerHint       // Hint for sorted trove insertion
) external payable
```

**No `collAmount` parameter** — collateral amount is implicit in `msg.value`.

This is **identical to Liquity**. No differences.

---

## Contract Addresses (Mezo Testnet - Chain ID 31611)

| Contract | Address |
|---|---|
| BorrowerOperations | `0xCdF7028ceAB81fA0C6971208e83fa7872994beE5` |
| TroveManager | `0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0` |
| MUSD Token | `0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503` |
| PriceFeed | `0x86bCF0841622a5dAC14A313a15f96A95421b9366` |
| HintHelpers | `0x4e4cBA3779d56386ED43631b4dCD6d8EacEcBCF6` |
| SortedTroves | `0x722E4D24FD6Ff8b0AC679450F3D91294607268fA` |

---

## Complete Example Code (TypeScript + viem)

```typescript
import { createWalletClient, createPublicClient, http, parseEther } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

// Mezo Testnet config
const mezoTestnet = {
  id: 31611,
  name: 'Mezo Testnet',
  nativeCurrency: { name: 'Bitcoin', symbol: 'BTC', decimals: 18 },
  rpcUrls: {
    default: { http: ['https://rpc.test.mezo.org'] },
  },
};

const account = privateKeyToAccount('0x...');  // Your private key

const walletClient = createWalletClient({
  account,
  chain: mezoTestnet,
  transport: http(),
});

const publicClient = createPublicClient({
  chain: mezoTestnet,
  transport: http(),
});

// Contract addresses
const BORROWER_OPS = '0xCdF7028ceAB81fA0C6971208e83fa7872994beE5';
const TROVE_MANAGER = '0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0';
const HINT_HELPERS = '0x4e4cBA3779d56386ED43631b4dCD6d8EacEcBCF6';
const SORTED_TROVES = '0x722E4D24FD6Ff8b0AC679450F3D91294607268fA';

// Step 1: Get gas compensation constant (200 MUSD)
const gasComp = await publicClient.readContract({
  address: TROVE_MANAGER,
  abi: [{ 
    name: 'MUSD_GAS_COMPENSATION', 
    type: 'function', 
    stateMutability: 'view', 
    inputs: [], 
    outputs: [{ type: 'uint256' }] 
  }],
  functionName: 'MUSD_GAS_COMPENSATION',
});

// Step 2: Calculate hints for gas-efficient insertion
const collateralAmount = parseEther('0.05');  // 0.05 BTC
const debtAmount = parseEther('3000');        // 3,000 MUSD

// Get borrowing fee
const fee = await publicClient.readContract({
  address: BORROWER_OPS,
  abi: [{ 
    name: 'getBorrowingFee', 
    type: 'function', 
    stateMutability: 'view', 
    inputs: [{ type: 'uint256' }], 
    outputs: [{ type: 'uint256' }] 
  }],
  functionName: 'getBorrowingFee',
  args: [debtAmount],
});

const totalDebt = debtAmount + fee + gasComp;
const nicr = (collateralAmount * 10n**20n) / totalDebt;  // NICR = collateral * 1e20 / debt

const [approxHint] = await publicClient.readContract({
  address: HINT_HELPERS,
  abi: [{ 
    name: 'getApproxHint', 
    type: 'function', 
    stateMutability: 'view', 
    inputs: [
      { type: 'uint256' }, 
      { type: 'uint256' }, 
      { type: 'uint256' }
    ], 
    outputs: [
      { type: 'address' }, 
      { type: 'uint256' }, 
      { type: 'uint256' }
    ] 
  }],
  functionName: 'getApproxHint',
  args: [nicr, 15n, 42n],  // numTrials=15, randomSeed=42
});

const [upperHint, lowerHint] = await publicClient.readContract({
  address: SORTED_TROVES,
  abi: [{ 
    name: 'findInsertPosition', 
    type: 'function', 
    stateMutability: 'view', 
    inputs: [
      { type: 'uint256' }, 
      { type: 'address' }, 
      { type: 'address' }
    ], 
    outputs: [
      { type: 'address' }, 
      { type: 'address' }
    ] 
  }],
  functionName: 'findInsertPosition',
  args: [nicr, approxHint, approxHint],
});

// Step 3: Open the trove
const hash = await walletClient.writeContract({
  address: BORROWER_OPS,
  abi: [{ 
    name: 'openTrove', 
    type: 'function', 
    stateMutability: 'payable',
    inputs: [
      { name: '_debtAmount', type: 'uint256' },
      { name: '_upperHint', type: 'address' },
      { name: '_lowerHint', type: 'address' }
    ],
  }],
  functionName: 'openTrove',
  args: [debtAmount, upperHint, lowerHint],
  value: collateralAmount,  // ← Send BTC collateral as msg.value
});

console.log('Transaction hash:', hash);

// Wait for confirmation
const receipt = await publicClient.waitForTransactionReceipt({ hash });
console.log('Trove opened! Block:', receipt.blockNumber);
```

---

## Key Concepts

### What is a Trove?

A **trove** is what Liquity (and MUSD) calls a **CDP (Collateralized Debt Position)**. It's your individual loan position that tracks:
- How much BTC collateral you deposited
- How much MUSD debt you owe
- Your current collateral ratio (CR)

### Why Do I Need Hints?

The trove list is maintained as a sorted doubly-linked list ordered by collateral ratio. To insert your new trove efficiently, you need to provide "hints" (addresses of neighboring troves). Without hints, the contract would need to scan the entire list, costing 10x+ more gas.

The hint calculation process:
1. Calculate your NICR (Nominal Individual Collateral Ratio)
2. Use `HintHelpers.getApproxHint()` to get an approximate position
3. Use `SortedTroves.findInsertPosition()` to get exact neighbors
4. Pass these as `upperHint` and `lowerHint` to `openTrove()`

### Gas Compensation

Every trove must pay a **200 MUSD gas compensation** that gets held in the protocol's GasPool. This is returned to liquidators who close underwater troves. Your total debt will be:

```
Total Debt = Borrowed Amount + Borrowing Fee + 200 MUSD
```

### Minimum Requirements

- **Minimum debt:** 1,800 MUSD (borrowing less will revert)
- **Minimum collateral ratio (MCR):** 110%
- **Borrowing fee:** ~0.1% (governable)

Example:
- To borrow 3,000 MUSD, you need:
  - Debt: 3,000 + 3 (0.1% fee) + 200 (gas comp) = 3,203 MUSD
  - Collateral: 3,203 × 1.10 = 3,523.30 USD worth of BTC minimum
  - At $100k/BTC: 0.035233 BTC minimum

---

## Important Notes

1. **Send BTC as `msg.value`** — no ERC-20 approve needed
2. **You MUST compute hints** — otherwise gas costs are astronomical (10x+ higher)
3. **Don't forget the gas compensation** — your total debt = `debtAmount + fee + 200 MUSD`
4. **Monitor your collateral ratio** — if it drops below 110%, your trove can be liquidated
5. **The Pikolo project** (Mezo Hackathon finalist) uses this exact pattern, confirming it works

---

## Additional Resources

- **Mezo Testnet RPC:** `https://rpc.test.mezo.org`
- **Mezo Testnet Explorer:** `https://explorer.test.mezo.org`
- **Mezo Testnet Faucet:** `https://faucet.test.mezo.org/`
- **MUSD GitHub Repo:** `https://github.com/mezo-org/musd`
- **Mezo Documentation:** `https://mezo.org/docs/developers/musd/`

---

## Troubleshooting

### Transaction Reverts with "BorrowerOps: An operation that would result in ICR < MCR is not permitted"

Your collateral ratio is too low. Increase `collateralAmount` or decrease `debtAmount`.

### Transaction Reverts with "BorrowerOps: Trove's net debt must be greater than minimum"

You're trying to borrow less than 1,800 MUSD. Increase `debtAmount` to at least 1,800.

### Hints are Stale

If someone else opened/closed a trove between when you calculated hints and submitted the transaction, your hints might be invalid. Recalculate and retry.

### Very High Gas Costs

You're not using hints correctly. Make sure you're calling `getApproxHint()` and `findInsertPosition()` before calling `openTrove()`.

---

## Next Steps

After opening a trove:
- Monitor your collateral ratio via `TroveManager.getCurrentICR(address)`
- Add more collateral with `BorrowerOperations.addColl()`
- Borrow more with `BorrowerOperations.withdrawMUSD()`
- Repay debt with `BorrowerOperations.repayMUSD()`
- Close trove with `BorrowerOperations.closeTrove()`
