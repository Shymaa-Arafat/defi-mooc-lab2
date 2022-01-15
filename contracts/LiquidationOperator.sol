//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "hardhat/console.sol";

// ----------------------INTERFACE------------------------------

// Aave
// https://docs.aave.com/developers/the-core-protocol/lendingpool/ilendingpool

interface ILendingPool {
    /**
     * Function to liquidate a non-healthy position collateral-wise, with Health Factor below 1
     * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
     *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
     * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of theliquidation
     * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
     * @param user The address of the borrower getting liquidated
     * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
     * @param receiveAToken `true` if the liquidators wants to receive the collateral aTokens, `false` if he wants
     * to receive the underlying collateral asset directly
     **/
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    /**
     * Returns the user account data across all the reserves
     * @param user The address of the user
     * @return totalCollateralETH the total collateral in ETH of the user
     * @return totalDebtETH the total debt in ETH of the user
     * @return availableBorrowsETH the borrowing power left of the user
     * @return currentLiquidationThreshold the liquidation threshold of the user
     * @return ltv the loan to value of the user
     * @return healthFactor the current health factor of the user
     **/
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

// UniswapV2

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IERC20.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/Pair-ERC-20
interface IERC20 {
    // Returns the account balance of another account with address _owner.
    function balanceOf(address owner) external view returns (uint256);

    /**
     * Allows _spender to withdraw from your account multiple times, up to the _value amount.
     * If this function is called again it overwrites the current allowance with _value.
     * Lets msg.sender set their allowance for a spender.
     **/
    function approve(address spender, uint256 value) external; // return type is deleted to be compatible with USDT

    /**
     * Transfers _value amount of tokens to address _to, and MUST fire the Transfer event.
     * The function SHOULD throw if the message caller’s account balance does not have enough tokens to spend.
     * Lets msg.sender send pool tokens to an address.
     **/
    function transfer(address to, uint256 value) external returns (bool);
}

// https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IWETH.sol
interface IWETH is IERC20 {
    // Convert the wrapped token back to Ether.
    function withdraw(uint256) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Callee.sol
// The flash loan liquidator we plan to implement this time should be a UniswapV2 Callee
interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Factory.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/factory
interface IUniswapV2Factory {
    // Returns the address of the pair for tokenA and tokenB, if it has been created, else address(0).
    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Pair.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/pair
interface IUniswapV2Pair {
    /**
     * Swaps tokens. For regular swaps, data.length must be 0.
     * Also see [Flash Swaps](https://docs.uniswap.org/protocol/V2/concepts/core-concepts/flash-swaps).
     **/
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    /**
     * Returns the reserves of token0 and token1 used to price trades and distribute liquidity.
     * See Pricing[https://docs.uniswap.org/protocol/V2/concepts/advanced-topics/pricing].
     * Also returns the block.timestamp (mod 2**32) of the last block during which an interaction occured for the pair.
     **/
    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );
}

// ----------------------IMPLEMENTATION------------------------------
//Shymaa fork code embedding starts from here


//Shymaa fork code embedding starts from here

    contract LiquidationOperator is IUniswapV2Callee {
    uint8 public constant health_factor_decimals = 18;

    // TODO: define constants used in the contract including ERC-20 tokens, Uniswap Pairs, Aave lending pools, etc. */
    address payable owner;
    address ETH_TOKEN_ADDRESS = address(0x0);
    
    address wbtcAddress = address(0x2260fac5e5542a773aa44fbcfedf7c193bc2c599);
    ERC20 wbtcToken = ERC20(wethAddress);
    address contractAddress = address(0xb7990f251451a89728eb2aa7b0a529f51d127478);
    address usdtAddress = address(0xdac17f958d2ee523a2206206994597c13d831ec7);
    ERC20 usdtToken = ERC20(usdtAddress);
    // END TODO

    // some helper function, it is totally fine if you can finish the lab without using these function
    // https://github.com/Uniswap/v2-periphery/blob/master/contracts/libraries/UniswapV2Library.sol
    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // some helper function, it is totally fine if you can finish the lab without using these function
    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }


    constructor() {
        // TODO: (optional) initialize your contract
        //   *** Your code here ***
       // owner = msg.sender;
        // END TODO
    }

    // TODO: add a `receive` function so that you can withdraw your WETH
    //   *** Your code here ***
    receive() external payable {}
    // END TODO

    // required by the testing script, entry for your liquidation call
    function operate() external {
        // TODO: implement your liquidation logic

        // 0. security checks and initializing variables
        //    *** Your code here ***

        // 1. get the target user account data & make sure it is liquidatable
        //    *** Your code here ***
        address user_account = address(0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F);
        position = ILendingPool.getUserAccountData(user_account);
        bool liquitable = (position.healthFactor < 1);

        uint256 repay1=(position.totalDebtETH)*(position.ltv-1)/(1.066*position.currentLiquidationThreshold-1);
        //This is the value that make health factor still<1, Aave documents say LS=6.5% so I made it 1.066 to make repay slightly less
        
        // 2. call flash swap to liquidate the target user
        // based on https://etherscan.io/tx/0xac7df37a43fab1b130318bbb761861b8357650db2e2c6493b73d6da3d9581077
        // we know that the target user borrowed USDT with WBTC as collateral
        // we should borrow USDT, liquidate the target user and get the WBTC, then swap WBTC to repay uniswap
        // (please feel free to develop other workflows as long as they liquidate the target user successfully)
        //    *** Your code here ***

        address usdt_wbtc_pair = IUniswapV2Factory.getPair(usdtToken, wbtcToken);
        if (liquitable){
            uniswapV2Call(usdt_wbtc_pair,(0.6* position.totalDebthETH), 0, data);
        //I'm taking a Flashloan that is roughly larger than both liquidation steps, since no harm is done if it is larger
        }


        // 3. Convert the profit into ETH and send back to sender
        //    *** Your code here ***

        // END TODO
    }

    // required by the swap
    function uniswapV2Call(
        address,
        uint256,
        uint256 amount1,
        bytes calldata
    ) external override {
        // TODO: implement your liquidation logic

        // 2.0. security checks and initializing variables
        //    *** Your code here ***

        address token0 = IUniswapV2Pair(msg.sender).token0(); // fetch the address of token0
        address token1 = IUniswapV2Pair(msg.sender).token1(); // fetch the address of token1
        assert(msg.sender == IUniswapV2Factory(factoryV2).getPair(token0, token1)); // ensure that msg.sender is a V2 pair
        
        // rest of the function goes here!
        // 2.1 liquidate the target user
        //    *** Your code here ***
        ILendingPool.liquidationCall(token0, token1, address(this), uint(-1), false); //changed from Aave to -1 limit 
        
        // 2.2 swap WBTC for other things or repay directly
        //    *** Your code here ***
        /* //code for 1 liquidation
        unit amountRequired = getAmountIn(sender, token0, token1);
        IUniswapV2Pair.swap(amount0Out, amountRequired, address (this), data);

        // 2.3 repay
        //    *** Your code here ***
        IERC20.approve(sender, amountRequired);
        IERC20.transfer(sender, amountRequired);
        // END TODO*/
        
 //This is to do 2 liquidation steps
        ILendingPool.liquidationCall(token0, token1, address(this), repay1, false); //changed from Aave to -1 limit 
        
        // 2.2 swap WBTC for other things or repay directly
        unit amountRequired = getAmountIn(sender, token0, token1);
        IUniswapV2Pair.swap(amount0Out, amountRequired, address (this), data);
        // 2.3 repay
        IERC20.approve(sender, amountRequired);
        IERC20.transfer(sender, amountRequired);
        
//now 2nd liquidation
        ILendingPool.liquidationCall(token0, token1, address(this), uint(-1), false); //changed from Aave to -1 limit 
       
        // 2.2 swap WBTC for other things or repay directly
        unit amountRequired = getAmountIn(sender, token0, token1);
        IUniswapV2Pair.swap(amount0Out, amountRequired, address (this), data);
        // 2.3 repay
        IERC20.approve(sender, amountRequired);
        IERC20.transfer(sender, amountRequired);

    }
}
    
