pragma solidity ^0.5.0;

import "../tokens/TokenModule.sol";

contract CustomTokenModule is TokenModule {
    string public description;

    constructor(address _tokenAddress)
    TokenModule(_tokenAddress, "custom")
    public
    {
    }
}
