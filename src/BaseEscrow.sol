// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { AuthNoOwner } from "./Dependencies/AuthNoOwner.sol";
import { IEscrow } from "./Dependencies/IEscrow.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


contract BaseEscrow is AuthNoOwner, IEscrow {
    using SafeERC20 for IERC20;

    IERC20 public immutable ASSET_TOKEN;
    address public immutable BSM;
    address public immutable FEE_RECIPIENT;

    /// @notice total user deposit amount
    uint256 public totalAssetsDeposited;

    error CallerNotBSM();

    /// @notice Modifier to restrict function calls to the BSM
    modifier onlyBSM() {
        if (msg.sender != BSM) {
            revert CallerNotBSM();
        }
        _;
    }

    
    constructor(address _assetToken, address _bsm, address _governance, address _feeRecipient) {
        ASSET_TOKEN = IERC20(_assetToken);
        BSM = _bsm;
        FEE_RECIPIENT = _feeRecipient;
        _initializeAuthority(_governance);

        // allow the BSM to transfer asset tokens
        ASSET_TOKEN.forceApprove(BSM, type(uint256).max); /// safe approve
    }

    /// @dev Internal function that checks the total balance of assets held by the contract
    function _totalBalance() internal virtual view returns (uint256) {
        return ASSET_TOKEN.balanceOf(address(this));
    }

   
    function _onDeposit(uint256 _assetAmount) internal virtual {
        totalAssetsDeposited += _assetAmount;
    }

   
    function _onWithdraw(uint256 _assetAmount) internal virtual returns (uint256) {
        totalAssetsDeposited -= _assetAmount;
       
        return _assetAmount;
    }

   
    function _previewWithdraw(uint256 _assetAmount) internal virtual view returns (uint256) {
        return _assetAmount;
    }

   
    function _withdrawProfit(uint256 _profitAmount) internal virtual {
        ASSET_TOKEN.safeTransfer(FEE_RECIPIENT, _profitAmount);
    }

    /// @notice Prepares the escrow for migration
    function _beforeMigration() internal virtual {
        // Do nothing
    }

    /// @notice Internal function to claim profits generated from fees and external lending
    function _claimProfit() internal {
        uint256 profit = feeProfit();
        if (profit > 0) {
            _withdrawProfit(profit);
            // INVARIANT: total balance must be >= deposit amount
            require(_totalBalance() >= totalAssetsDeposited);
        }        
    }

    /// @notice Returns the total balance of assets in the escrow
    function totalBalance() external view returns (uint256) {
        return _totalBalance();
    }

  
    function onDeposit(uint256 _assetAmount) external onlyBSM {
        _onDeposit(_assetAmount);
    }

   
    function onWithdraw(uint256 _assetAmount) external onlyBSM returns (uint256) {
        return _onWithdraw(_assetAmount);
    }

    function previewWithdraw(uint256 _assetAmount) external view returns (uint256) {
        /// @dev derived contracts can override _previewWithdraw to report potential losses
        return _previewWithdraw(_assetAmount);
    }

   
    function onMigrateSource(address _newEscrow) external onlyBSM {
        /// @dev take profit first (totalBalance == depositAmount after)
        _claimProfit();

        /// @dev clear depositAmount in old vault (address(this))
        totalAssetsDeposited = 0;

        /// @dev perform pre-migration tasks (potentially used by derived contracts)
        _beforeMigration();

        /// @dev transfer all liquidity to new vault
        ASSET_TOKEN.safeTransfer(_newEscrow, ASSET_TOKEN.balanceOf(address(this)));
    }

   
    function onMigrateTarget(uint256 _amount) external onlyBSM {
        totalAssetsDeposited = _amount;
    }

   
    function feeProfit() public view returns (uint256) {
        uint256 tb = _totalBalance();
        if(tb > totalAssetsDeposited) {
            unchecked {
                return tb - totalAssetsDeposited;
            }
        }

        return 0;
    }

    
    function claimProfit() external requiresAuth {
        _claimProfit();
    }
}
