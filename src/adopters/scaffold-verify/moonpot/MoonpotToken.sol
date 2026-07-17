// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

contract MoonpotToken is ERC20, Ownable2Step {
    error CannotResetManager();
    error InvalidAddress();
    error Unauthorized();

    event Minted(address indexed to, uint256 amount);
    event ManagerSet(address indexed _manager);

    address public manager;

    modifier onlyManager() {
        if (msg.sender != manager) revert Unauthorized();
        _;
    }

    constructor() ERC20("The Moonpot Token", "TMP") Ownable(msg.sender) {}

    function setManager(address _manager) external onlyOwner {
        if (_manager == address(0)) revert InvalidAddress();
        if (manager != address(0)) revert CannotResetManager();

        manager = _manager;
        emit ManagerSet(_manager);
    }

    function mint(address to, uint256 amount) external onlyManager {
        _mint(to, amount);
        emit Minted(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
