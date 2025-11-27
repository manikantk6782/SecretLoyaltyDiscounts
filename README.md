# Secret Loyalty Discounts

Privacy-preserving loyalty scoring and discount issuance on Zama FHEVM.

This dApp lets merchants run **behavior-based loyalty programs** where:

* Customers submit a **single encrypted loyalty score** (uint16).
* The contract compares it against **encrypted tier thresholds** and selects an appropriate **encrypted discount**.
* The user decrypts their discount locally via Zama’s **Relayer SDK**.
* Merchants never see your raw score, tier logic, or internal thresholds – only that a discount can be applied.

Built for the Zama FHEVM testnet on **Ethereum Sepolia**.

---

## Table of Contents

1. [Concept](#concept)
2. [How It Works](#how-it-works)

   * [Actors](#actors)
   * [Encrypted Policy Model](#encrypted-policy-model)
   * [Discount Evaluation](#discount-evaluation)
3. [Smart Contract](#smart-contract)

   * [Key Data Structures](#key-data-structures)
   * [Main Functions](#main-functions)
4. [Frontend App](#frontend-app)

   * [User Flow](#user-flow)
   * [Admin Flow](#admin-flow)
   * [Relayer SDK usage](#relayer-sdk-usage)
5. [Project Structure](#project-structure)
6. [Running Locally](#running-locally)
7. [Security & Privacy Notes](#security--privacy-notes)
8. [Potential Extensions](#potential-extensions)

---

## Concept

**Problem:** Traditional loyalty programs expose a lot of data:

* detailed behavior metrics
* thresholds for tiers
* exact logic for computing discounts

**Goal:** Issue discounts **without revealing**:

* the user’s raw loyalty score
* the merchant’s thresholds and scoring model
* the reasoning behind why a discount was granted or denied

**Solution:** Use Zama’s FHEVM to keep the entire loyalty policy **encrypted on-chain**, and only decrypt the **final discount** client-side.

High level:

* Merchant defines a *program* with encrypted thresholds & discounts.
* User submits an encrypted score.
* Contract computes the matching encrypted discount.
* User decrypts only the discount via the Relayer SDK.

---

## How It Works

### Actors

* **User**

  * Computes their own loyalty score off-chain (any arbitrary formula).
  * Encrypts the score via the Relayer SDK and submits it to the contract.
  * Later decrypts the resulting discount locally in the browser.

* **Merchant / Owner**

  * Owns the `SecretLoyaltyDiscounts` contract.
  * Configures loyalty programs via encrypted thresholds and discounts.
  * Never sees cleartext scores or discounts.

---

### Encrypted Policy Model

Each **program** is identified by `programId` (e.g. 1, 2, 3 …).

For each `programId`, the contract stores:

* 3 encrypted **minimum loyalty scores** (tier thresholds)
* 3 encrypted **discount values** (basis points, e.g. 500 = 5%)

All of these are stored as FHE **euint16**; the contract only works with encrypted values.

---

### Discount Evaluation

When a user calls `submitEncryptedLoyalty(programId, encScore, proof)`:

1. The frontend encrypts the user’s loyalty score using the Relayer SDK and Zama Gateway.
2. The contract ingests the encrypted score (`externalEuint16`) and converts it to `euint16` using `FHE.fromExternal`.
3. It compares the encrypted score with encrypted thresholds using FHE comparison operators.
4. It selects an encrypted discount amount corresponding to the highest tier the user qualifies for.
5. It stores two encrypted fields in a per-user, per-program mapping:

   * `eScore` – encrypted loyalty score
   * `eDiscountBps` – encrypted discount in basis points
6. The contract emits handles that the user can decrypt off-chain via the Relayer.

At no point does the chain see cleartext scores or discount values.

---

## Smart Contract

> Contract name: **`SecretLoyaltyDiscounts`**
> Network: **Ethereum Sepolia (FHEVM)**
> Address: `0xa1dc30F21517605E3e8Ee51dF7a7697dD46974BC`

The contract uses Zama’s FHE Solidity library:

```solidity
import { FHE, ebool, euint16, externalEuint16 } from "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
```

### Key Data Structures

* **Owner**

  * `address public owner` – simple ownable pattern.

* **ProgramConfig**

  * `bool exists` – whether the program is configured.
  * `euint16 eMinScoreTier1` – encrypted minimum score for tier 1.
  * `euint16 eMinScoreTier2` – encrypted minimum score for tier 2.
  * `euint16 eMinScoreTier3` – encrypted minimum score for tier 3.
  * `euint16 eDiscountTier1` – encrypted discount for tier 1.
  * `euint16 eDiscountTier2` – encrypted discount for tier 2.
  * `euint16 eDiscountTier3` – encrypted discount for tier 3.

* **UserLoyalty**

  * `euint16 eScore` – encrypted loyalty score submitted by the user.
  * `euint16 eDiscountBps` – encrypted discount (basis points).
  * `bool decided` – whether a decision has already been computed.

---

### Main Functions

#### Ownership

* `function transferOwnership(address newOwner) external onlyOwner`

  * Transfers contract ownership to another address.

---

#### Program configuration (admin only)

* `function setProgramPolicy(...) external onlyOwner`

  * Takes 6 encrypted values from the Relayer Gateway:

    * 3 encrypted minimum scores
    * 3 encrypted discounts
  * Uses `FHE.fromExternal` and `FHE.allowThis` to ingest and persist them.

* `function removeProgram(uint256 programId) external onlyOwner`

  * Disables a program by marking `exists = false`.

* `function getProgramMeta(uint256 programId) external view returns (bool exists)`

  * View-only: says whether a program is configured.

* `function getProgramPolicyHandles(uint256 programId) external view returns (bytes32[6])`

  * Returns handles for the encrypted thresholds & discounts.
  * Intended for analytics tools or debugging (still encrypted).

---

#### User flow (encrypted)

* `function submitEncryptedLoyalty(uint256 programId, externalEuint16 encScore, bytes calldata proof)`

  * User-facing entry point.
  * Ingests the encrypted score + proof from the Zama Gateway.
  * Performs FHE comparisons to determine which discount tier applies.
  * Stores encrypted score and encrypted discount in `UserLoyalty`.
  * Grants `FHE.allow` rights so the user can decrypt their own ciphertexts.

* `function getMyLoyaltyHandles(uint256 programId) external view returns (bytes32 scoreHandle, bytes32 discountHandle, bool decided)`

  * Pure view: returns handles for the caller’s latest loyalty decision.
  * No FHE operations inside – only handle extraction.

* `function getUserDiscountHandle(address user, uint256 programId) external view returns (bytes32 discountHandle, bool decided)`

  * Allows external systems to retrieve the encrypted discount handle for a specific user.
  * The handle is **not** publicly decryptable – the user still controls decryption via ACL.

---

## Frontend App

The frontend is a **single HTML/JS file** that talks directly to:

* MetaMask / EIP-1193 wallet (via `ethers.js` `BrowserProvider`)
* Zama Relayer SDK (for encryption & decryption)
* The deployed `SecretLoyaltyDiscounts` contract

It is designed as a **clean, card-based UI** with clear separation between:

* user view (submit score + decrypt discount)
* admin view (configure program policies)

### User Flow

1. **Connect wallet**

   * Connect via MetaMask.
   * UI ensures you’re on **Sepolia** and shows the contract address.

2. **Select a program**

   * Enter `Program ID` or use quick buttons (#1, #2).
   * Click **“Check on-chain”** to verify whether the program exists.

3. **Submit loyalty score**

   * Enter an integer `0–65535` as your **loyalty score**.
   * Frontend uses `relayer.createEncryptedInput(CONTRACT_ADDRESS, account)` then `add16(score)` to build encrypted input.
   * It calls `submitEncryptedLoyalty(programId, handle, proof)`.

4. **Decrypt discount**

   * Click **“Decrypt my discount”**.
   * Frontend fetches handles via `getMyLoyaltyHandles(programId)`.
   * It runs `userDecrypt` through the Relayer SDK to decrypt both score & discount.
   * Only the **discount** is shown, as a percentage (basis points → %).

> The frontend strictly avoids leaking internal values back to the chain.

---

### Admin Flow

1. Connect with the **owner** address.
2. The UI marks you as `role: owner`.
3. In the **Admin · Configure loyalty programs** card:

   * Enter `Program ID`.
   * Fill in:

     * `Tier 1/2/3 min score` (uint16)
     * `Tier 1/2/3 discount` (uint16 basis points)
   * Click **“Encrypt & set program policy”**.
4. The UI:

   * Encrypts all 6 numbers with `createEncryptedInput`, `add16` six times.
   * Sends all 6 handles + proof to `setProgramPolicy`.

The merchant never handles raw ciphertexts manually—everything is done via the Relayer.

---

### Relayer SDK usage

The frontend uses:

```js
import { initSDK, createInstance, SepoliaConfig, generateKeypair } from "https://cdn.zama.org/relayer-sdk-js/0.3.0-5/relayer-sdk-js.js";
```

Patterns used:

* **Safe JSON logging** with BigInt:

```js
const safeStringify = (obj) =>
  JSON.stringify(obj, (k, v) => (typeof v === "bigint" ? v.toString() + "n" : v), 2);

function appendLog(...parts) {
  const msg = parts.map(x =>
    typeof x === "string" ? x : (() => { try { return safeStringify(x); } catch { return String(x); } })()
  ).join(" ");
  console.log("📜[secret-loyalty]", msg);
}
```

* **Decrypted value normalization**:

```js
function normalizeDecryptedValue(v) {
  if (v == null) return null;
  if (typeof v === "boolean") return v ? 1n : 0n;
  if (typeof v === "bigint" || typeof v === "number") return BigInt(v);
  if (typeof v === "string") return BigInt(v);
  return BigInt(v.toString());
}
```

* **userDecrypt flow** (EIP-712 signing):

```js
const kp = await generateKeypair();
const startTs = Math.floor(Date.now() / 1000).toString();
const daysValid = "7";

const eip = relayer.createEIP712(kp.publicKey, [CONTRACT_ADDRESS], startTs, daysValid);
const sig = await signer.signTypedData(
  eip.domain,
  { UserDecryptRequestVerification: eip.types.UserDecryptRequestVerification },
  eip.message
);

const userAddr = await signer.getAddress();
const out = await relayer.userDecrypt(
  pairs,
  kp.privateKey,
  kp.publicKey,
  sig.replace(/^0x/, ""),
  [CONTRACT_ADDRESS],
  userAddr,
  startTs,
  daysValid
);
```

The result is parsed via a `buildValuePicker` helper that knows how to interpret different Relayer output layouts (`clearValues`, `abiEncodedClearValues`, or map-like structures).

---

## Project Structure

A minimal layout could look like:

```text
.
├─ contracts/
│  └─ SecretLoyaltyDiscounts.sol      # FHEVM loyalty contract
├─ frontend/
│  └─ index.html                      # Single-page dApp (this repo’s HTML)
├─ scripts/
│  └─ deploy.ts                       # Hardhat (or Foundry) deployment script
├─ hardhat.config.ts                  # Hardhat configuration (via-IR + optimizer recommended)
└─ README.md                          # This file
```

You can adapt this structure to your existing Hardhat / Foundry setup.

---

## Running Locally

1. **Install dependencies** (example with Hardhat):

```bash
yarn install
# or
npm install
```

2. **Configure FHEVM & networks**

Make sure your Hardhat config points to the Zama FHEVM Sepolia-compatible RPC and that the FHEVM Solidity library is installed:

```bash
yarn add @fhevm/solidity
```

3. **Compile & deploy contract** (example):

```bash
npx hardhat compile
npx hardhat deploy --network sepolia
```

Update the frontend `CONTRACT_ADDRESS` constant with the deployed address.

4. **Serve the frontend over HTTPS** (recommended)

Because the Relayer SDK uses WASM workers and EIP-712 signing, browsers behave best over HTTPS.

For quick local testing you can use something like:

```bash
npx http-server ./frontend -S -C cert.pem -K key.pem -p 3443
```

Then open:

```text
https://localhost:3443
```

The app will auto-detect the `localhost:3443` proxy and route Relayer traffic through it.

---

## Security & Privacy Notes

* **All scoring logic is off-chain**

  * The contract never sees how you computed your loyalty score.

* **Encrypted thresholds and discounts**

  * Program policies are stored as FHE ciphertexts.
  * Contract uses only encrypted comparisons and selections.

* **No public certificates**

  * There is no `enablePublicCertificate`-style call.
  * Discount handles are ACL-protected; only the user (via `userDecrypt`) can see the discount.

* **Views expose handles only**

  * View functions return `bytes32` handles, never cleartext.
  * No FHE operations are performed inside views.

* **Reentrancy-safe design**

  * The core update functions are structured to avoid reentrancy issues.

---

## Potential Extensions

Some ideas to extend this prototype:

* **Multi-merchant support** – map `programId` + `merchant` to policies.
* **Time-bounded programs** – add encrypted or plaintext validity periods per program.
* **Multi-dimensional scoring** – expand a single score to several encrypted metrics combined under FHE.
* **Proof-of-usage** – allow users to present discounted purchases without revealing the original score.
* **Off-chain analytics** – build dashboards that work on encrypted aggregates via public decrypt for aggregate-only stats.

---

## License

MIT – use, modify, and build upon this project free
