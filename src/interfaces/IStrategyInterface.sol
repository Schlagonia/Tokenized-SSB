// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {IBaseHealthCheck} from "@periphery/HealthCheck/IBaseHealthCheck.sol";

interface IStrategyInterface is IBaseHealthCheck {
    function pool() external view returns (address);

    function open() external view returns (bool);

    function allowed(address) external view returns (bool);

    function tradeFactory() external view returns (address);

    function maxSingleTrade() external view returns (uint256);

    function maxTendBasefee() external view returns (uint256);

    function depositTrigger() external view returns (uint256);

    function slippage() external view returns (uint256);

    function fromAssetToBpt(uint256 _amount) external view returns (uint256);

    function fromBptToAsset(uint256 _amount) external view returns (uint256);

    function totalLpBalance() external view returns (uint256);

    function balanceOfPool() external view returns (uint256);

    function balanceOfStake() external view returns (uint256);

    function setTradeFactory(address _tradeFactory) external;

    function setMaxSingleTrade(uint256 _maxSingleTrade) external;

    function setMaxTendBasefee(uint256 _maxTendBasefee) external;

    function setDepositTrigger(uint256 _depositTrigger) external;

    function setSlippage(uint256 _slippage) external;

    function setOpen(bool _open) external;

    function setAllowed(address _address, bool _allowed) external;

    function manualWithdraw(uint256 _amount) external;
}
