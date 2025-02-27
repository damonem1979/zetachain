// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router01.sol";

import "../interfaces/IZRC4.sol";
import "../interfaces/zContract.sol";

interface ZetaSwapErrors {
    error WrongGasContract();

    error NotEnoughToPayGasFee();

    error CantBeIdenticalAddresses();

    error CantBeZeroAddress();
}

contract ZetaSwap is zContract, ZetaSwapErrors {
    uint16 internal constant MAX_DEADLINE = 200;

    address public zetaToken;
    address public immutable uniswapV2Router;

    constructor(address zetaToken_, address uniswapV2Router_) {
        zetaToken = zetaToken_;
        uniswapV2Router = uniswapV2Router_;
    }

    // returns sorted token addresses, used to handle return values from pairs sorted in this order
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        if (tokenA == tokenB) revert CantBeIdenticalAddresses();
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert CantBeZeroAddress();
    }

    // calculates the CREATE2 address for a pair without making any external calls
    function uniswapv2PairFor(
        address factory,
        address tokenA,
        address tokenB
    ) public pure returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            factory,
                            keccak256(abi.encodePacked(token0, token1)),
                            hex"96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f" // init code hash
                        )
                    )
                )
            )
        );
    }

    function encode(
        address zrc4,
        address recipient,
        uint256 minAmountOut
    ) public pure returns (bytes memory) {
        return abi.encode(zrc4, recipient, minAmountOut);
    }

    function _doWithdrawal(
        address targetZRC4,
        uint256 amount,
        bytes32 receipient
    ) private {
        (address gasZRC4, uint256 gasFee) = IZRC4(targetZRC4).withdrawGasFee();

        if (gasZRC4 != targetZRC4) revert WrongGasContract();
        if (gasFee >= amount) revert NotEnoughToPayGasFee();

        IZRC4(targetZRC4).approve(targetZRC4, gasFee);
        IZRC4(targetZRC4).withdraw(abi.encodePacked(receipient), amount - gasFee);
    }

    function onCrossChainCall(
        address zrc4,
        uint256 amount,
        bytes calldata message
    ) external override {
        (address targetZRC4, bytes32 receipient, uint256 minAmountOut) = abi.decode(
            message,
            (address, bytes32, uint256)
        );

        address uniswapPool = uniswapv2PairFor(uniswapV2Router, zrc4, targetZRC4);
        bool existsPairPool = IZRC4(zrc4).balanceOf(uniswapPool) > 0 && IZRC4(zrc4).balanceOf(zetaToken) > 0;

        address[] memory path;
        if (existsPairPool) {
            path = new address[](2);
            path[0] = zrc4;
            path[1] = targetZRC4;
        } else {
            path = new address[](3);
            path[0] = zrc4;
            path[1] = zetaToken;
            path[2] = targetZRC4;
        }

        IZRC4(zrc4).approve(address(uniswapV2Router), amount);
        uint256[] memory amounts = IUniswapV2Router01(uniswapV2Router).swapExactTokensForTokens(
            amount,
            minAmountOut,
            path,
            address(this),
            block.timestamp + MAX_DEADLINE
        );

        _doWithdrawal(targetZRC4, amounts[1], receipient);
    }
}
