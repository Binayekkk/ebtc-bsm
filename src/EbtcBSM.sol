// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {AuthNoOwner} from "./Dependencies/AuthNoOwner.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IEbtcToken} from "./Dependencies/IEbtcToken.sol";
import {IEbtcBSM} from "./Dependencies/IEbtcBSM.sol";
import {IMintingConstraint} from "./Dependencies/IMintingConstraint.sol";
import {IEscrow} from "./Dependencies/IEscrow.sol";


contract EbtcBSM is IEbtcBSM, Pausable, Initializable, AuthNoOwner {
    using SafeERC20 for IERC20;

    /// @notice Basis points constant for percentage calculations
    uint256 public constant BPS = 10000;

    /// @notice Maximum allowable fees in basis points
    uint256 public constant MAX_FEE = 2000;

    /// @notice Underlying asset token for eBTC
    IERC20 public immutable ASSET_TOKEN;

    /// @notice eBTC token contract
    IEbtcToken public immutable EBTC_TOKEN;

    /// @notice Fee for selling assets into eBTC (in basis points)
    uint256 public feeToSellBPS;

    /// @notice Fee for buying assets with eBTC (in basis points)
    uint256 public feeToBuyBPS;

    /// @notice Total amount of eBTC minted
    uint256 public totalMinted;

    /// @notice Escrow contract to hold asset tokens
    IEscrow public escrow;

    /// @notice Oracle-based price constraint for minting
    IMintingConstraint public oraclePriceConstraint;

    /// @notice Rate limiting constraint for minting
    IMintingConstraint public rateLimitingConstraint;

    /// @notice Error for when there are insufficient asset tokens available
    error InsufficientAssetTokens(uint256 required, uint256 available);

    /// @notice Error for when the actual output amount is below the expected amount
    error BelowExpectedMinOutAmount(uint256 expected, uint256 actual);

    /// @notice Error for when the amount passed into sellAsset or buyAsset is zero
    error ZeroAmount();

    /// @notice Error for when the recipient address is the zero address
    error InvalidRecipientAddress();

  
    constructor(
        address _assetToken,
        address _oraclePriceConstraint,
        address _rateLimitingConstraint,
        address _ebtcToken,
        address _governance
    ) {
        require(_assetToken != address(0));
        require(_oraclePriceConstraint != address(0));
        require(_rateLimitingConstraint != address(0));
        require(_ebtcToken != address(0));
        require(_governance != address(0));

        ASSET_TOKEN = IERC20(_assetToken);
        oraclePriceConstraint = IMintingConstraint(_oraclePriceConstraint);
        rateLimitingConstraint = IMintingConstraint(_rateLimitingConstraint);
        EBTC_TOKEN = IEbtcToken(_ebtcToken);
        _initializeAuthority(_governance);
    }

   
    function initialize(address _escrow) initializer external {
        require(_escrow != address(0));
        escrow = IEscrow(_escrow);
    }

   
    function _feeToBuy(uint256 _amount) private view returns (uint256) {
        return (_amount * feeToBuyBPS) / BPS;
    }

    /** @notice Calculates the fee for selling eBTC
    * @param _amount Amount of eBTC to sell
    * @return Fee amount
    */
    function _feeToSell(uint256 _amount) private view returns (uint256) {
        uint256 fee = feeToSellBPS;
        return (_amount * fee) / (fee + BPS);
    }

    function _previewSellAsset(
        uint256 _assetAmountIn,
        uint256 _feeAmount
    ) private view returns (uint256 _ebtcAmountOut) {
        _ebtcAmountOut = _assetAmountIn - _feeAmount;
        _checkMintingConstraints(_ebtcAmountOut);
    }

    function _previewBuyAsset(
        uint256 _ebtcAmountIn,
        uint256 _feeAmount
    ) private view returns (uint256 _assetAmountOut) {
        _checkTotalAssetsDeposited(_ebtcAmountIn);
        _assetAmountOut = escrow.previewWithdraw(_ebtcAmountIn) - _feeAmount;
    }

   
    function _checkTotalAssetsDeposited(uint256 amountToBuy) private view {
        // ebtc to asset price is treated as 1 for buyAsset
        uint256 totalAssetsDeposited = escrow.totalAssetsDeposited();
        if (amountToBuy > totalAssetsDeposited) {
            revert InsufficientAssetTokens(amountToBuy, totalAssetsDeposited);
        }
    }
   
    function _checkMintingConstraints(uint256 _amountToMint) private view {
        bool success;
        bytes memory errData;

        (success, errData) = oraclePriceConstraint.canMint(_amountToMint, address(this));
        if (!success) {
            revert IMintingConstraint.MintingConstraintCheckFailed(
                address(oraclePriceConstraint),
                _amountToMint,
                address(this),
                errData
            );
        }

        (success, errData) = rateLimitingConstraint.canMint(_amountToMint, address(this));
        if (!success) {
            revert IMintingConstraint.MintingConstraintCheckFailed(
                address(rateLimitingConstraint),
                _amountToMint,
                address(this),
                errData
            );
        }
    }

    /// @notice Internal sellAsset function with an expected fee amount
    function _sellAsset(
        uint256 _assetAmountIn,
        address _recipient,
        uint256 _feeAmount,
        uint256 _minOutAmount
    ) internal returns (uint256 _ebtcAmountOut) {
        if (_assetAmountIn == 0) revert ZeroAmount();
        if (_recipient == address(0)) revert InvalidRecipientAddress();
    
        _ebtcAmountOut = _assetAmountIn - _feeAmount;

        _checkMintingConstraints(_ebtcAmountOut);

        // INVARIANT: _assetAmountIn >= _ebtcAmountOut
        ASSET_TOKEN.safeTransferFrom(
            msg.sender,
            address(escrow),
            _assetAmountIn
        );
        escrow.onDeposit(_ebtcAmountOut); // ebtcMinted = _assetAmountIn - fee

        // slippage check
        if (_ebtcAmountOut < _minOutAmount) {
            revert BelowExpectedMinOutAmount(_minOutAmount, _ebtcAmountOut);
        }

        totalMinted += _ebtcAmountOut;

        EBTC_TOKEN.mint(_recipient, _ebtcAmountOut);

        emit AssetSold(_assetAmountIn, _ebtcAmountOut, _feeAmount);
    }

    /// @notice Internal buyAsset function with an expected fee amount
    function _buyAsset(
        uint256 _ebtcAmountIn,
        address _recipient,
        uint256 _feeAmount,
        uint256 _minOutAmount
    ) internal returns (uint256 _assetAmountOut) {
        if (_ebtcAmountIn == 0) revert ZeroAmount();
        if (_recipient == address(0)) revert InvalidRecipientAddress();

        _checkTotalAssetsDeposited(_ebtcAmountIn);

        EBTC_TOKEN.burn(msg.sender, _ebtcAmountIn);

        totalMinted -= _ebtcAmountIn;

        uint256 redeemedAmount = escrow.onWithdraw(
            _ebtcAmountIn
        );

        _assetAmountOut = redeemedAmount - _feeAmount;

        // slippage check
        if (_assetAmountOut < _minOutAmount) {
            revert BelowExpectedMinOutAmount(_minOutAmount, _assetAmountOut);
        }

        if (_assetAmountOut > 0) {
            // INVARIANT: _assetAmountOut <= _ebtcAmountIn
            ASSET_TOKEN.safeTransferFrom(
                address(escrow),
                _recipient,
                _assetAmountOut
            );
        }

        emit AssetBought(_ebtcAmountIn, _assetAmountOut, _feeAmount);
    }

   
    function previewSellAsset(
        uint256 _assetAmountIn
    ) external returns (uint256 _ebtcAmountOut) {
        return _previewSellAsset(_assetAmountIn, _feeToSell(_assetAmountIn));
    }

    
    function previewBuyAsset(
        uint256 _ebtcAmountIn
    ) external returns (uint256 _assetAmountOut) {
        return _previewBuyAsset(_ebtcAmountIn, _feeToBuy(_ebtcAmountIn));
    }

   
    function sellAsset(
        uint256 _assetAmountIn,
        address _recipient,
        uint256 _minOutAmount
    ) external whenNotPaused returns (uint256 _ebtcAmountOut) {
        return
            _sellAsset(_assetAmountIn, _recipient, _feeToSell(_assetAmountIn), _minOutAmount);
    }

   
    function buyAsset(
        uint256 _ebtcAmountIn,
        address _recipient,
        uint256 _minOutAmount
    ) external whenNotPaused returns (uint256 _assetAmountOut) {
        return _buyAsset(_ebtcAmountIn, _recipient, _feeToBuy(_ebtcAmountIn), _minOutAmount);
    }

    
    function sellAssetNoFee(
        uint256 _assetAmountIn,
        address _recipient,
        uint256 _minOutAmount
    ) external whenNotPaused requiresAuth returns (uint256 _ebtcAmountOut) {
        return _sellAsset(_assetAmountIn, _recipient, 0, _minOutAmount);
    }

  
    function buyAssetNoFee(
        uint256 _ebtcAmountIn,
        address _recipient,
        uint256 _minOutAmount
    ) external whenNotPaused requiresAuth returns (uint256 _assetAmountOut) {
        return _buyAsset(_ebtcAmountIn, _recipient, 0, _minOutAmount);
    }

   
    function setFeeToSell(uint256 _feeToSellBPS) external requiresAuth {
        require(_feeToSellBPS <= MAX_FEE);
        emit FeeToSellUpdated(feeToSellBPS, _feeToSellBPS);
        feeToSellBPS = _feeToSellBPS;
    }

   
    function setFeeToBuy(uint256 _feeToBuyBPS) external requiresAuth {
        require(_feeToBuyBPS <= MAX_FEE);
        emit FeeToBuyUpdated(feeToBuyBPS, _feeToBuyBPS);
        feeToBuyBPS = _feeToBuyBPS;
    }

  
    function setRateLimitingConstraint(address _newRateLimitingConstraint) external requiresAuth {
        require(_newRateLimitingConstraint != address(0), "Invalid address");
        emit IMintingConstraint.MintingConstraintUpdated(address(rateLimitingConstraint), _newRateLimitingConstraint);
        rateLimitingConstraint = IMintingConstraint(_newRateLimitingConstraint);
    }

  
    function setOraclePriceConstraint(address _newOraclePriceConstraint) external requiresAuth {
        require(_newOraclePriceConstraint != address(0));
        emit IMintingConstraint.MintingConstraintUpdated(address(oraclePriceConstraint), _newOraclePriceConstraint);
        oraclePriceConstraint = IMintingConstraint(_newOraclePriceConstraint);
    }

   
    function updateEscrow(address _newEscrow) external requiresAuth {
        require(_newEscrow != address(0));

        uint256 totalBalance = escrow.totalBalance();
        if (totalBalance > 0) {
            /// @dev cache deposit amount (will be set to 0 after migrateTo())
            uint256 totalAssetsDeposited = escrow.totalAssetsDeposited();

            /// @dev transfer liquidity to new vault
            escrow.onMigrateSource(_newEscrow);

            /// @dev set totalAssetsDeposited on the new vault (fee amount should be 0 here)
            IEscrow(_newEscrow).onMigrateTarget(totalAssetsDeposited);
        }

        emit EscrowUpdated(address(escrow), _newEscrow);
        escrow = IEscrow(_newEscrow);
    }

    
    function pause() external requiresAuth {
        _pause();
    }

    
    function unpause() external requiresAuth {
        _unpause();
    }
}

