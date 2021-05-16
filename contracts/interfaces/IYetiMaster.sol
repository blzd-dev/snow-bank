// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IYetiMaster {
    function add(
        uint256 _allocPoint,
        address _want,
        bool _withUpdate,
        address _strat,
        uint16 _depositFeeBP
    ) external;

    function xBLZD() external view returns (address);
    
    function deposit(uint256 _pid,uint256 _wantAmt) external;
}
