//I will copy it here, no easy rename option in mobile
//This is a modified version with 2 steps liquidation added by me on 31/5/2022
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

interface ILendingPoolAddressesProvider {
    function getLendingPool() external view returns (address);
    function getLendingPoolCore() external view returns (address payable);
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

// Found at https://docs.uniswap.org/protocol/V2/reference/smart-contracts/router-02
interface IUniswapV2Router02 {
    function WETH () external returns (address);

    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts);
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

// ----------------------IMPLEMENTATION------------------------------

contract LiquidationOperator is IUniswapV2Callee {
    uint8 public constant health_factor_decimals = 18;
    uint256 public repay1=0;

    // define constants used in the contract including ERC-20 tokens, Uniswap Pairs, Aave lending pools, etc. */
    address target_address = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F; // loan of USDT collateralized with WBTC
    address loaner_address = 0xa61e59faC455EED933405ecDde9928982B478CE7;
    uint64 block_number = 1621761058;

    address me = address(this);
    
    // mainnet address, for other addresses: https://docs.aave.com/developers/developing-on-aave/deployed-contract-instances
    ILendingPoolAddressesProvider provider = ILendingPoolAddressesProvider(address(0x24a42fD28C976A61Df5D00D0599C34c4f90748c8));     
    ILendingPool lending_pool = ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    ILendingPool lendingPool = ILendingPool(provider.getLendingPool());
    IUniswapV2Router02 uniswap_router = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);


    address USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    IUniswapV2Factory uni_factory = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
   
    IUniswapV2Pair weth_usdt_uniswap = IUniswapV2Pair(uni_factory.getPair(WETH, USDT));
   

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
        // END TODO
    }

    // add a `receive` function so that you can withdraw your WETH
    receive() external payable {}

    // required by the testing script, entry for your liquidation call
    function operate() external {
        // implement your liquidation logic

        // 0. security checks and initializing variables
        //    *** Your code here ***

        // 1. get the target user account data & make sure it is liquidatable

        // totalCollateralETH is equivalent to WBTC borrowed
        // totalDebtETH is equivalent to USDT owed by loan

        // we know that the target user borrowed USDT with WBTC as collateral
        // so we should borrow USDT using Uniswap

        uint256 healthFactor;
        uint256 Collateral_ETH;
        uint256 Debt_ETH;
        uint256 LqThrshld;
        uint256 ltv;

        (Collateral_ETH,Debt_ETH , ,LqThrshld ,ltv , healthFactor) = lending_pool.getUserAccountData(target_address);
        require(healthFactor < 1e18, "health factor should be < 1 before liquidation");
        console.log("position is liquitable with HF=",healthFactor);
        console.log("total collateral value in ETH=",Collateral_ETH/1e18);
        console.log("The total debt is %d", Debt_ETH/1e18);
        console.log("Liquidation Threshold = %d", LqThrshld);
        console.log("LTV= ", ltv);
        uint256 usdt_amount_in_eth = 1799900000000; //the no I wrote is by adding the 1st repay value
        console.log("Amount to borrow in USDT is %s tokens", usdt_amount_in_eth);
        console.log("let's check it is really there ? USDT =",IERC20(USDT).balanceOf(me));
      
        weth_usdt_uniswap.swap(0, usdt_amount_in_eth, me, "not null for flash swap");
        console.log("back from flash swap call; ie finished, I supposed to have the remaining WBTC after paying the flashloan");

        uint256 balance_in_wbtc = IERC20(WBTC).balanceOf(me);
        console.log("balance in wbt =this is what remains in supposely my account after paying back the flashloan:");
        console.log("in WBTC=", balance_in_wbtc);
        console.log("in WETH=",IERC20(WETH).balanceOf(me));

        // 2. call flash swap to liquidate the target user VIA uniswapV2Call
        // based on https://etherscan.io/tx/0xac7df37a43fab1b130318bbb761861b8357650db2e2c6493b73d6da3d9581077
        
       
        
        // (please feel free to develop other workflows as long as they liquidate the target user successfully)
        //    *** Your code here ***
        
        // 3. Convert the profit into ETH and send back to sender
        //    convert WETH to ETH
        //    *** Your code here ***

        IERC20(WBTC).approve(address(uniswap_router), (2**256)-1); // just approve max  
        address[] memory pair = new address[](2);
        pair[0] = address(IERC20(WBTC));
        pair[1] =  address(IERC20(WETH));
       // pair[1] =  address(IWETH(WETH));
        
        uniswap_router.swapExactTokensForETH(balance_in_wbtc, 0, pair, msg.sender, block_number);

        uint256 weth_balance = IWETH(WETH).balanceOf(me);
        console.log("now after actual transformation, my balance in WETH=",IERC20(pair[1]).balanceOf(me));
        console.log("weth-balance=",weth_balance);
        IWETH(WETH).withdraw(weth_balance);
        payable(msg.sender).transfer(weth_balance);
        console.log("now after actual transformation, my balance in WETH=",IERC20(WETH).balanceOf(me));
        console.log("in WBTC=", IERC20(WBTC).balanceOf(me));
        console.log("weth-balance=",weth_balance);
     

    }

    // required by the swap
    function uniswapV2Call(
        address sender,
        uint256,
        //uint256 amount0, // should be 0 = amount in WETH to be given to pool
        uint256 amount1, // should be usdt_amount_in_weth = amout of USDT to be taken from pool
        bytes calldata
    ) external override {
        // implement your liquidation logic

        // 2.0. security checks and initializing variables
        //    *** Your code here ***

        // console.log tool edstem

        // 2.1 liquidate the target user
        //    *** Your code here ***

        // then liquidate the target user on Aave and get the WBTC collateral back

        uint112 reserves_wbtc;
        uint112 reserves_weth;
        
        uint256 balance_in_wbtc = IERC20(WBTC).balanceOf(sender);
        console.log("now we have just entered the uniswap call we don't have any WBTC  before liquidation balance is zero = %d tokens", balance_in_wbtc);
        
        
        //1st liquidation
        repay1=97711111111;
        console.log("1st repay=",repay1);
        IERC20(USDT).approve(address(lending_pool), repay1);
        (reserves_wbtc, reserves_weth, ) = IUniswapV2Pair(msg.sender).getReserves();
        lending_pool.liquidationCall(address(WBTC), address(USDT), target_address, repay1, false);
        balance_in_wbtc = IERC20(WBTC).balanceOf(sender);
        console.log("Now after 1st liquidation WBTC balance=", balance_in_wbtc);
        
        //2nd liquidation
       { uint256 healthFactor;
        uint256 Collateral_ETH;
        uint256 Debt_ETH;
        //uint256 availableBorrowsETH;
        uint LqThrshld;
        uint ltv;

        (Collateral_ETH,Debt_ETH , ,LqThrshld ,ltv , healthFactor) = lending_pool.getUserAccountData(target_address);
        require(healthFactor < 1e18, "health factor should be < 1 before liquidation");
        if(healthFactor < 1e18) console.log("position is still liquitable proceed to 2nd liquidation with HF=",healthFactor);
        console.log("total collateral value in ETH after 1st lquidation=",Collateral_ETH/1e18);
        console.log("The total debt is %d", Debt_ETH/1e18);
        console.log("Liquidation Threshold = %d", LqThrshld);
        console.log("LTV= ", ltv);
        } 
        
        
        balance_in_wbtc = IERC20(WBTC).balanceOf(sender);
        console.log("for debugging do we still have our WBTC balance after position? WBTC=", balance_in_wbtc);
        IERC20(USDT).approve(address(lending_pool), (2**256)-1); // just approve for max
        ( reserves_wbtc, reserves_weth, ) = IUniswapV2Pair(msg.sender).getReserves();
        console.log("remaining=",amount1-repay1); 
        balance_in_wbtc = IERC20(USDT).balanceOf(me);
        console.log("for debugging do we still have our USDT balance after uniswapv2pair? USDT=", balance_in_wbtc);
        balance_in_wbtc = IERC20(WBTC).balanceOf(sender);
        console.log("for debugging do we still have our WBTC balance uniswapv2pair? WBTC=", balance_in_wbtc);
        console.log("reserves_wbtc=",reserves_wbtc);
        console.log("reserves_weth=",reserves_weth);
        
        
        lending_pool.liquidationCall(address(WBTC), address(USDT), target_address, amount1-repay1, false);

        balance_in_wbtc = IERC20(WBTC).balanceOf(me);
        console.log("After 2nd liquidation WBTC Balance, is it added or overwritten? WBTC=", balance_in_wbtc);
        balance_in_wbtc = IERC20(USDT).balanceOf(me);
        console.log("After 2nd liquidation USDT Balance, is me different than sender? USDT=", balance_in_wbtc);
        balance_in_wbtc = IERC20(WETH).balanceOf(me);
        console.log("After 2nd liquidation WETH Balance, is me different than sender? WETH=", balance_in_wbtc);
        //These r the pool reserves just checked for sufficient liquidity actually no need to print them
        //console.log("reserves_wbtc=",reserves_wbtc);
        //console.log("reserves_weth=",reserves_weth);
       
        
        // // 2.2 swap WBTC for other things or repay directly
        // //    *** Your code here ***

        // // 2.3 repay
        // //    *** Your code here ***

        // // then swap WBTC for WETH to repay uniswap

        IERC20(WBTC).approve(address(uniswap_router), (2**256)-1); // just approve max  
        
        address[] memory pair = new address[](2);
        pair[0] = address(WBTC);
        pair[1] = address(WETH);
        uint256 amountIn = getAmountIn(amount1, reserves_wbtc, reserves_weth);
        console.log("Routing for exact swap");
        uniswap_router.swapTokensForExactTokens(amountIn, (2**256)-1, pair, msg.sender, block_number);
        balance_in_wbtc = IERC20(WBTC).balanceOf(me);
        console.log("After uniswap router WBTC Balance,  WBTC=", balance_in_wbtc);
        balance_in_wbtc = IERC20(USDT).balanceOf(me);
        console.log("                     USDT Balance,  USDT=", balance_in_wbtc);
        balance_in_wbtc = IERC20(WETH).balanceOf(me);
        console.log("                     WETH Balance,  WETH=", balance_in_wbtc);
        console.log("reserves_wbtc=",reserves_wbtc);
        console.log("reserves_weth=",reserves_weth);

    }
}
