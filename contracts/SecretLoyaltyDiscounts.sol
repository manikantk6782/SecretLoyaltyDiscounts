// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
  FHE,
  ebool,
  euint16,
  externalEuint16
} from "@fhevm/solidity/lib/FHE.sol";

import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract SecretLoyaltyDiscounts is ZamaEthereumConfig {
  // -------- Ownership --------
  address public owner;

  modifier onlyOwner() {
    require(msg.sender == owner, "Not owner");
    _;
  }

  constructor() {
    owner = msg.sender;
  }

  function transferOwnership(address newOwner) external onlyOwner {
    require(newOwner != address(0), "zero owner");
    owner = newOwner;
  }

  // -------- Simple nonReentrant guard --------
  uint256 private _locked = 1;

  modifier nonReentrant() {
    require(_locked == 1, "reentrancy");
    _locked = 2;
    _;
    _locked = 1;
  }

  // ---------------------------------------------------------------------------
  // Encrypted program configuration
  // ---------------------------------------------------------------------------

  struct ProgramConfig {
    bool exists;
    // encrypted minimum loyalty score thresholds for tiers
    euint16 eMinScoreTier1;
    euint16 eMinScoreTier2;
    euint16 eMinScoreTier3;
    // encrypted discount values for tiers (e.g. percentage basis points)
    euint16 eDiscountTier1;
    euint16 eDiscountTier2;
    euint16 eDiscountTier3;
  }

  // programId => config
  mapping(uint256 => ProgramConfig) private programs;

  event ProgramPolicySet(uint256 indexed programId);
  event ProgramRemoved(uint256 indexed programId);

  /**
   * Configure / update encrypted loyalty policy for a program.
   *
   * All values are encrypted off-chain and passed as externalEuint16.
   * One proof is provided (gateway attestation) and reused here.
   */
  function setProgramPolicy(
    uint256 programId,
    externalEuint16 encMinScoreTier1,
    externalEuint16 encMinScoreTier2,
    externalEuint16 encMinScoreTier3,
    externalEuint16 encDiscountTier1,
    externalEuint16 encDiscountTier2,
    externalEuint16 encDiscountTier3,
    bytes calldata proof
  ) external onlyOwner {
    require(programId != 0, "invalid programId");
    require(proof.length != 0, "missing proof");

    ProgramConfig storage P = programs[programId];
    P.exists = true;

    // Use single temp variable to avoid stack-too-deep
    euint16 tmp;

    // tier 1 min score
    tmp = FHE.fromExternal(encMinScoreTier1, proof);
    FHE.allowThis(tmp);
    P.eMinScoreTier1 = tmp;

    // tier 2 min score
    tmp = FHE.fromExternal(encMinScoreTier2, proof);
    FHE.allowThis(tmp);
    P.eMinScoreTier2 = tmp;

    // tier 3 min score
    tmp = FHE.fromExternal(encMinScoreTier3, proof);
    FHE.allowThis(tmp);
    P.eMinScoreTier3 = tmp;

    // discount tier 1
    tmp = FHE.fromExternal(encDiscountTier1, proof);
    FHE.allowThis(tmp);
    P.eDiscountTier1 = tmp;

    // discount tier 2
    tmp = FHE.fromExternal(encDiscountTier2, proof);
    FHE.allowThis(tmp);
    P.eDiscountTier2 = tmp;

    // discount tier 3
    tmp = FHE.fromExternal(encDiscountTier3, proof);
    FHE.allowThis(tmp);
    P.eDiscountTier3 = tmp;

    emit ProgramPolicySet(programId);
  }

  function removeProgram(uint256 programId) external onlyOwner {
    ProgramConfig storage P = programs[programId];
    require(P.exists, "not found");
    delete programs[programId];
    emit ProgramRemoved(programId);
  }

  function getProgramMeta(uint256 programId) external view returns (bool exists) {
    ProgramConfig storage P = programs[programId];
    return P.exists;
  }

  /**
   * Owner-only: expose encrypted policy handles (for debugging / analytics).
   */
  function getProgramPolicyHandles(uint256 programId)
    external
    view
    onlyOwner
    returns (
      bytes32 minScoreTier1Handle,
      bytes32 minScoreTier2Handle,
      bytes32 minScoreTier3Handle,
      bytes32 discountTier1Handle,
      bytes32 discountTier2Handle,
      bytes32 discountTier3Handle
    )
  {
    ProgramConfig storage P = programs[programId];
    require(P.exists, "Program does not exist");

    return (
      FHE.toBytes32(P.eMinScoreTier1),
      FHE.toBytes32(P.eMinScoreTier2),
      FHE.toBytes32(P.eMinScoreTier3),
      FHE.toBytes32(P.eDiscountTier1),
      FHE.toBytes32(P.eDiscountTier2),
      FHE.toBytes32(P.eDiscountTier3)
    );
  }

  // ---------------------------------------------------------------------------
  // User loyalty (encrypted scores & discounts)
  // ---------------------------------------------------------------------------

  struct LoyaltyState {
    euint16 eScore;     // encrypted loyalty score
    euint16 eDiscount;  // encrypted discount the user gets
    bool decided;       // set after at least one evaluation
  }

  // user => programId => state
  mapping(address => mapping(uint256 => LoyaltyState)) private loyalty;

  event LoyaltyEvaluated(
    address indexed user,
    uint256 indexed programId,
    bytes32 scoreHandle,
    bytes32 discountHandle
  );

  /**
   * User submits an encrypted loyalty score for a program.
   *
   * Contract:
   * - compares score against encrypted thresholds (tier 1/2/3),
   * - picks corresponding encrypted discount value,
   * - stores both score & discount encrypted,
   * - gives user decryption rights for both.
   */
  function submitEncryptedLoyalty(
    uint256 programId,
    externalEuint16 encScore,
    bytes calldata proof
  ) external nonReentrant {
    ProgramConfig storage P = programs[programId];
    require(P.exists, "Program does not exist");
    require(proof.length != 0, "proof required");

    LoyaltyState storage S = loyalty[msg.sender][programId];

    // Ingest encrypted loyalty score
    euint16 eScore = FHE.fromExternal(encScore, proof);
    FHE.allowThis(eScore);
    FHE.allow(eScore, msg.sender);

    euint16 eZero = FHE.asEuint16(0);

    // encrypted comparisons: score >= minTierX ?
    ebool atLeastTier1 = FHE.ge(eScore, P.eMinScoreTier1);
    ebool atLeastTier2 = FHE.ge(eScore, P.eMinScoreTier2);
    ebool atLeastTier3 = FHE.ge(eScore, P.eMinScoreTier3);

    // Use FHE.select instead of removed cmux:
    // base = atLeastTier1 ? disc1 : 0
    euint16 eDiscBase = FHE.select(atLeastTier1, P.eDiscountTier1, eZero);
    // then override with tier2 if applicable
    euint16 eDisc2 = FHE.select(atLeastTier2, P.eDiscountTier2, eDiscBase);
    // then override with tier3 if applicable
    euint16 eFinalDiscount = FHE.select(atLeastTier3, P.eDiscountTier3, eDisc2);

    // store encrypted state
    S.eScore = eScore;
    S.eDiscount = eFinalDiscount;
    S.decided = true;

    // keep long-term rights for contract
    FHE.allowThis(S.eScore);
    FHE.allowThis(S.eDiscount);

    // allow user to decrypt both score & discount
    FHE.allow(S.eScore, msg.sender);
    FHE.allow(S.eDiscount, msg.sender);

    emit LoyaltyEvaluated(
      msg.sender,
      programId,
      FHE.toBytes32(S.eScore),
      FHE.toBytes32(S.eDiscount)
    );
  }

  // ---------------------------------------------------------------------------
  // Getters (handles only)
  // ---------------------------------------------------------------------------

  /**
   * User view: get own encrypted loyalty score & discount handles.
   * Frontend will use Relayer SDK userDecrypt(...) with these handles.
   */
  function getMyLoyaltyHandles(uint256 programId)
    external
    view
    returns (bytes32 scoreHandle, bytes32 discountHandle, bool decided)
  {
    LoyaltyState storage S = loyalty[msg.sender][programId];
    return (FHE.toBytes32(S.eScore), FHE.toBytes32(S.eDiscount), S.decided);
  }

  /**
   * Merchant / owner view: get user's encrypted discount handle.
   * Still can't see the numeric value, only the ciphertext handle.
   */
  function getUserDiscountHandle(address user, uint256 programId)
    external
    view
    onlyOwner
    returns (bytes32 discountHandle, bool decided)
  {
    LoyaltyState storage S = loyalty[user][programId];
    return (FHE.toBytes32(S.eDiscount), S.decided);
  }
}
