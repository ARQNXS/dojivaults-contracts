// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {LedgerUSDC, CIDiamond} from "./ConservationMocks.sol";
import {CIWorld} from "./ConservationWorld.sol";
import {CIHandler, CIValuer} from "./ConservationHandler.sol";

/// @notice Round 2, domain CI. The global checks of the conservation invariant, shared by the forge invariant test and
///         the Medusa harness. Each returns (ok, the first failing property) and never reverts on a false property.
contract CIChecker {
    CIWorld public immutable w;
    CIHandler public immutable h;
    GainsVault internal immutable vault;
    LedgerUSDC internal immutable usdc;
    CIDiamond internal immutable diamond;

    constructor(CIWorld w_, CIHandler h_) {
        w = w_;
        h = h_;
        vault = w_.vault();
        usdc = w_.usdc();
        diamond = w_.diamond();
    }

    /// @notice Fairness, claims, flows and collateral counters kept by the handler (all must be 0).
    function fairness() public view returns (bool, string memory) {
        if (h.vF1HolderDiluted() != 0) return (false, "F1 a settle lowered the holders' fair value per share");
        if (h.vF1dDepositPrice() != 0) return (false, "F1d deposit shares != max(advNAV, idle + favNAV) pricing");
        if (h.vF1rRedeemPrice() != 0) return (false, "F1r redemption payout != adverse / checkpoint pricing");
        if (h.vS1HeldInFlight() != 0) return (false, "S1 a settle ran with collateral in flight (priced at 0)");
        if (h.vFeeAboveCap() != 0) return (false, "F3 fee shares above the configured fee");
        if (h.vFeeConfig() != 0) return (false, "F3 a fee rate above its hard cap");
        if (h.vProtocolShare() != 0) return (false, "F3 protocol share above its bps");
        if (h.vFeeRecipient() != 0) return (false, "F3 fee shares to someone else");
        if (h.vClaimOver() != 0) return (false, "F2 a delivery above the entitlement");
        if (h.vClaimShortWei() != 0) return (false, "F2 a delivery below the entitlement");
        if (h.vEpochOverpaid() != 0) return (false, "F2 an epoch's claims above its redeemAssets");
        if (h.vReturnedOver() != 0) return (false, "F2 returned shares above the unburned escrow");
        if (h.vDepSharesOver() != 0) return (false, "F2 deposit shares claimed above depositShares");
        if (h.vRefundOver() != 0) return (false, "F2 refunds above depositAssets");
        if (h.vLostRequest() != 0) return (false, "F2 a settled request with nothing recorded for it");
        if (h.vFlowMovedHolders() != 0) return (false, "R a depositor flow moved idle USDC, supply or the venue");
        if (h.vCancelInexact() != 0) return (false, "R a cancel returned != the request");
        if (h.vRedeemSharesMoved() != 0) return (false, "R requestRedeem escrowed != the shares");
        if (h.vCollateral() != 0) return (false, "C2 the diamond pulled != what a trader call asked");
        return (true, "");
    }

    /// @notice C1, C2, C3 and T4.
    function ledger() public view returns (bool, string memory) {
        address v = address(vault);
        if (usdc.strayOut() != 0) return (false, "C1 USDC left the vault to someone other than the diamond or the claimant");
        if (usdc.intoVault() != h.gDeposits() + h.gDonations()) return (false, "C1 USDC in != deposits + donations");
        if (usdc.paidOut() != h.gClaims() + h.gRefunds()) return (false, "C1 USDC out to users != claims + refunds");
        if (diamond.escrowLedger(v) != diamond.escrowOf(v)) return (false, "C2 venue ledger != venue state");
        if (usdc.toDiamond() != diamond.pulled(v)) return (false, "C2 collateral sent != collateral pulled");
        if (usdc.toDiamond() != h.gExpectedPull()) return (false, "C2 collateral pulled outside the vault's trader calls");
        if (usdc.fromDiamond() != diamond.paid(v)) return (false, "C2 a venue payout did not reach the vault");
        int256 lhs = int256(usdc.balanceOf(v) + diamond.escrowLedger(v));
        int256 rhs = int256(h.base() + h.gDeposits() + h.gDonations()) - int256(h.gRefunds() + h.gClaims())
            + int256(diamond.paid(v)) - int256(diamond.released(v));
        if (lhs != rhs) return (false, "C3 vault USDC + escrow != seed + deposits + donations - refunds - claims + venue P&L");
        if (usdc.allowance(v, address(diamond)) != 0) return (false, "T4 standing approval to the diamond");
        return (true, "");
    }

    /// @notice Reserves: backed, exact, covering every entitlement within the rounding bound; share escrow; supply.
    function reserves() public view returns (bool, string memory) {
        uint256 pend = vault.pendingDepositAssets() + vault.deferredDepositAssets();
        uint256 claimable = vault.claimableRedeemAssets();
        if (usdc.balanceOf(address(vault)) < pend + claimable) return (false, "R reserves not backed by USDC");
        address[5] memory a = w.actors();
        uint256 outstanding;
        uint256 owed;
        uint256 owedShares;
        uint256 cur = vault.currentEpoch();
        for (uint256 i; i < 5; ++i) {
            (uint256 e, uint256 dA, uint256 rS) = vault.requests(a[i]);
            if (dA > 0) {
                bool carried;
                if (e < cur) {
                    (uint256 cf, uint256 pi) = vault.carry(e);
                    carried = cf != 0 && pi == 0;
                }
                if (e >= cur || carried) outstanding += dA;
            }
            if (e < cur && (dA > 0 || rS > 0)) {
                (uint256 sh, uint256 as_) = entitlement(a[i]);
                owed += as_;
                owedShares += sh;
            }
        }
        if (pend != outstanding) return (false, "R pending + deferred != unpriced requests");
        if (claimable < owed) return (false, "R claimable does not cover every entitlement");
        if (claimable - owed > h.dustBound()) return (false, "R claimable slack above the rounding bound");
        if (vault.balanceOf(address(vault)) < vault.pendingRedeemShares() + owedShares) {
            return (false, "R share escrow does not cover queued + unclaimed shares");
        }
        uint256 held = vault.balanceOf(address(vault)) + vault.balanceOf(w.TREASURY());
        for (uint256 i; i < 5; ++i) {
            held += vault.balanceOf(a[i]);
        }
        if (held != vault.totalSupply()) return (false, "a share is held outside the known holders");
        return (true, "");
    }

    /// @notice N1: totalAssets() == idle + the independent adverse-edge valuation (skipped while a price is stale).
    function nav() public view returns (bool, string memory) {
        CIValuer.Venue memory v = h.venueNow();
        try vault.totalAssets() returns (uint256 n) {
            if (n != h.idleNow() + v.adv) return (false, "N1 NAV != idle + independent adverse valuation");
        } catch {}
        return (true, "");
    }

    /// @notice Entitlement of a settled request, from the epoch records (SPEC D6; the vault's formula is in
    ///         GainsVaultMath.claimableWithCarry).
    function entitlement(address c) public view returns (uint256 shares, uint256 assets) {
        (uint256 e, uint256 dA, uint256 rS) = vault.requests(c);
        if (dA > 0) {
            uint256 pe = e;
            (uint256 cf, uint256 pi) = vault.carry(e);
            bool carried = cf != 0 && pi == 0;
            if (cf != 0 && pi != 0) pe = pi - 1;
            if (!carried) {
                (uint256 pA, uint256 pS,,,,,,) = vault.epochs(pe);
                if (pA > 0) {
                    if (pS == 0) assets += dA;
                    else shares += Math.mulDiv(dA, pS, pA);
                }
            }
        }
        if (rS > 0) {
            (,, uint256 eS, uint256 eA, uint256 eB,,,) = vault.epochs(e);
            if (eS > 0) {
                assets += Math.mulDiv(rS, eA, eS);
                uint256 b = Math.mulDiv(rS, eB, eS, Math.Rounding.Ceil);
                if (b < rS) shares += rS - b;
            }
        }
    }
}
