// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {CompounderRegistry} from "./CompounderRegistry.sol";
import {IUserCompounder} from "./interfaces/IUserCompounder.sol";
import {CompounderLens} from "./CompounderLens.sol";

/// @title KeeperMulticall
/// @notice Protocol keeper entry point. Allowlisted operators batch `compoundAll()` calls across
///         user compounders that delegated to this contract. Gas reimbursements paid by the
///         compounders accumulate here. All selection data is exposed through views so an
///         off-chain bot can run without any local state.
contract KeeperMulticall is Ownable2Step, CompounderLens {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    enum Skip {
        None,
        NotCompounder,
        NotDelegated,
        Inactive,
        NoPositions,
        BelowThreshold,
        Unfunded
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event OperatorSet(address indexed operator, bool allowed);
    event BatchItem(address indexed compounder, bool success, uint256 gasUsed, bytes reason);
    event BatchDone(uint256 attempted, uint256 succeeded, uint256 ethReceived);
    event EthWithdrawn(address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotOperator();
    error NotCompounder(address compounder);
    error TransferFailed();
    error LengthMismatch();

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(address => bool) public operators;

    uint256 public totalBatches;
    uint256 public totalCompounds;
    uint256 public totalEthReceived;

    constructor(address _registry, address _owner) CompounderLens(_registry) {
        _transferOwnership(_owner);
    }

    modifier onlyOperator() {
        if (!operators[msg.sender] && msg.sender != owner()) revert NotOperator();
        _;
    }

    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                                  ADMIN
    //////////////////////////////////////////////////////////////*/

    function setOperator(address operator, bool allowed) external onlyOwner {
        operators[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }

    function withdrawETH(address to, uint256 amount) external onlyOwner {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit EthWithdrawn(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                  BATCH
    //////////////////////////////////////////////////////////////*/

    /// @notice Call `compoundAll()` on each compounder. Failures are isolated and reported.
    function batch(address[] calldata compounders) external onlyOperator returns (uint256 succeeded) {
        uint256 ethBefore = address(this).balance;
        for (uint256 i = 0; i < compounders.length; i++) {
            if (!registry.isCompounder(compounders[i])) revert NotCompounder(compounders[i]);
            uint256 g = gasleft();
            (bool ok, bytes memory reason) = compounders[i].call(abi.encodeCall(IUserCompounder.compoundAll, ()));
            uint256 used = g - gasleft();
            if (ok) succeeded++;
            emit BatchItem(compounders[i], ok, used, ok ? bytes("") : reason);
        }
        totalBatches++;
        totalCompounds += succeeded;
        uint256 received = address(this).balance - ethBefore;
        totalEthReceived += received;
        emit BatchDone(compounders.length, succeeded, received);
    }

    /// @notice Call `compound(tokenIds)` on each compounder with an explicit position list.
    function batchSelect(address[] calldata compounders, uint256[][] calldata tokenIds)
        external
        onlyOperator
        returns (uint256 succeeded)
    {
        if (compounders.length != tokenIds.length) revert LengthMismatch();
        uint256 ethBefore = address(this).balance;
        for (uint256 i = 0; i < compounders.length; i++) {
            if (!registry.isCompounder(compounders[i])) revert NotCompounder(compounders[i]);
            uint256 g = gasleft();
            (bool ok, bytes memory reason) =
                compounders[i].call(abi.encodeCall(IUserCompounder.compound, (tokenIds[i])));
            uint256 used = g - gasleft();
            if (ok) succeeded++;
            emit BatchItem(compounders[i], ok, used, ok ? bytes("") : reason);
        }
        totalBatches++;
        totalCompounds += succeeded;
        uint256 received = address(this).balance - ethBefore;
        totalEthReceived += received;
        emit BatchDone(compounders.length, succeeded, received);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Estimated gas reimbursement a compounder would owe for `gasEstimate` at `gasPrice`.
    function reimbursementFor(uint256 gasEstimate, uint256 gasPrice) public view returns (uint256) {
        CompounderRegistry.Config memory cfg = registry.config();
        uint256 price = gasPrice > cfg.maxGasPrice ? cfg.maxGasPrice : gasPrice;
        return ((gasEstimate + cfg.gasOverhead) * price * (10_000 + cfg.gasPremiumBps)) / 10_000;
    }

    /// @notice Apply the same rules the compounder enforces so bots never submit failing calls.
    /// @param minPendingUp Operator-side threshold on total pending UP (in addition to the user's).
    function isCompoundable(address compounder, uint256 gasPrice, uint256 gasEstimate, uint256 minPendingUp)
        external
        view
        returns (bool ok, Skip reason, IUserCompounder.CompounderSnapshot memory s)
    {
        if (!registry.isCompounder(compounder)) return (false, Skip.NotCompounder, s);
        s = snapshot(compounder);
        if (s.keeper != address(this)) return (false, Skip.NotDelegated, s);
        if (!s.active) return (false, Skip.Inactive, s);
        if (s.positionCount == 0) return (false, Skip.NoPositions, s);
        // Count only what `compoundAll()` would actually claim: it skips disabled pools and every
        // position below `minUpToCompound` on its own, but still reimburses the call.
        uint256 up = compoundableUp(compounder);
        if (up == 0 || up < minPendingUp) return (false, Skip.BelowThreshold, s);
        if (s.gasBalance < reimbursementFor(gasEstimate, gasPrice)) return (false, Skip.Unfunded, s);
        return (true, Skip.None, s);
    }
}
