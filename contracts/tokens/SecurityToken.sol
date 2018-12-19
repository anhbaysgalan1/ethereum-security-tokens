pragma solidity ^0.4.24;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "../utils/Factory.sol";
import "openzeppelin-solidity/contracts/lifecycle/Pausable.sol";
import "../utils/Bytes32ArrayLib.sol";
import "../utils/AddressArrayLib.sol";
import "./TokenModule.sol";

contract ISecurityToken is Pausable {
    // ERC-20

    uint256 public totalSupply;

    function balanceOf(address tokenHolder) public view returns (uint256);

    event Transfer(address indexed from, address indexed to, uint256 amount);

    // OKTO Security Token

    string public name;
    string public symbol;
    uint8 public decimals;
    address[] public operators;
    bool public released;

    // Modules handling
    function addModule(address moduleAddress) public;
    function removeModule(address moduleAddress) public;
    function release() public;

    // Operators handling
    function authorizeOperator(address operator) public;
    function revokeOperator(address operator) public;
    function isOperator(address operator) public view returns (bool);

    // Tokens handling
    function balanceOfByTranche(bytes32 tranche, address tokenHolder) public view returns (uint256);
    function getDestinationTranche(bytes32 sourceTranche, address from, uint256 amount, bytes data) public view returns(bytes32);
    function canTransfer(bytes32 tranche, address operator, address from, address to, uint256 amount, bytes data) public view returns (byte, string, bytes32);
    function transferByTranche(bytes32 tranche, address to, uint256 amount, bytes data) public returns (bytes32);
    function operatorTransferByTranche(bytes32 tranche, address from, address to, uint256 amount, bytes data) public returns (bytes32);
    function tranchesOf(address tokenHolder) public view returns (bytes32[]);
    function issueByTranche(bytes32 tranche, address tokenHolder, uint256 amount, bytes data) public;
    function burnByTranche(bytes32 tranche, address tokenHolder, uint256 amount, bytes data) public;

    // Events
    event AddedModule(address moduleAddress);
    event RemovedModule(address moduleAddress);
    event Released();
    event AuthorizedOperator(address indexed operator);
    event RevokedOperator(address indexed operator);
    event TransferByTranche(bytes32 fromTranche, bytes32 toTranche, address indexed operator, address indexed from, address indexed to, uint256 amount, bytes data);
    event IssuedByTranche(bytes32 tranche, address indexed operator, address indexed to, uint256 amount, bytes data);
    event BurnedByTranche(bytes32 tranche, address indexed operator, address indexed from, uint256 amount, bytes data);
}

contract SecurityToken is ISecurityToken {
    using SafeMath for uint256;

    mapping(address => mapping(bytes32 => uint256)) internal balancesPerTranche;
    mapping(address => uint256) internal balances;
    mapping(address => bytes32[]) internal tranches;

    // modules defined for the token
    address[] internal modules;
    address[] internal transferValidators;
    address[] internal transferListeners;
    address[] internal tranchesManagers;

    ///////////////////////////////////////////////////////////////////////////
    //
    // Modifiers
    //
    ///////////////////////////////////////////////////////////////////////////

    modifier isReleased()
    {
        require(released, "Token is not released");
        _;
    }

    modifier isDraft()
    {
        require(!released, "Token is already released");
        _;
    }

    modifier onlyOwnerTx() {
        require(msg.sender == owner || tx.origin == owner);
        _;
    }

    ///////////////////////////////////////////////////////////////////////////
    //
    // ERC-20 Standard Token
    //
    ///////////////////////////////////////////////////////////////////////////

    function balanceOf(address tokenHolder)
    public view returns (uint256)
    {
        return balances[tokenHolder];
    }

    ///////////////////////////////////////////////////////////////////////////
    //
    // OKTO Security Token - Modules handling
    //
    ///////////////////////////////////////////////////////////////////////////

    constructor(string _name, string _symbol, uint8 _decimals, address[] _operators)
    public
    {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        operators = _operators;
    }

    function addModule(address moduleAddress)
    onlyOwnerTx isDraft
    public
    {
        require(moduleAddress != address(0), "Module address is required");

        TokenModule module = TokenModule(moduleAddress);
        TokenModule.Feature[] memory features = module.getFeatures();

        require(features.length > 0, "Token module does not have any feature");

        for (uint i = 0; i < features.length; i++) {
            if (features[i] == TokenModule.Feature.TransferValidator) {
                AddressArrayLib.addIfNotPresent(transferValidators, moduleAddress);
            } else if (features[i] == TokenModule.Feature.TransferListener) {
                AddressArrayLib.addIfNotPresent(transferListeners, moduleAddress);
            } else if (features[i] == TokenModule.Feature.TranchesManager) {
                AddressArrayLib.addIfNotPresent(tranchesManagers, moduleAddress);
            }
        }

        AddressArrayLib.addIfNotPresent(modules, moduleAddress);

        emit AddedModule(moduleAddress);
    }

    function removeModule(address moduleAddress)
    onlyOwnerTx isDraft
    public
    {
        AddressArrayLib.removeValue(transferValidators, moduleAddress);
        AddressArrayLib.removeValue(transferListeners, moduleAddress);
        AddressArrayLib.removeValue(tranchesManagers, moduleAddress);
        AddressArrayLib.removeValue(modules, moduleAddress);

        emit RemovedModule(moduleAddress);
    }

    function isModule(address moduleAddress)
    public view returns (bool)
    {
        return AddressArrayLib.contains(modules, moduleAddress);
    }

    function release()
    onlyOwner
    public
    {
        require(!released, "Token already released");

        released = true;

        emit Released();
    }

    ///////////////////////////////////////////////////////////////////////////
    //
    // OKTO Security Token - Operators handling
    //
    ///////////////////////////////////////////////////////////////////////////

    function authorizeOperator(address operator)
    onlyOwner
    public
    {
        require(operator != address(0), "Invalid operator");

        AddressArrayLib.addIfNotPresent(operators, operator);

        emit AuthorizedOperator(operator);
    }

    function revokeOperator(address operator)
    onlyOwner
    public
    {
        AddressArrayLib.removeValue(operators, operator);

        emit RevokedOperator(operator);

    }

    function isOperator(address operator)
    public view returns (bool)
    {
        for (uint i = 0; i < operators.length; i++) {
            if (operators[i] == operator) {
                return true;
            }
        }
        return false;
    }

    ///////////////////////////////////////////////////////////////////////////
    //
    // OKTO Security Token - Tokens handling
    //
    ///////////////////////////////////////////////////////////////////////////

    function balanceOfByTranche(bytes32 tranche, address tokenHolder)
    public view returns (uint256)
    {
        return balancesPerTranche[tokenHolder][tranche];
    }

    function getDestinationTranche(bytes32 sourceTranche, address from, uint256 amount, bytes data)
    public view returns(bytes32)
    {
        // the default implementation is to transfer to the same tranche
        bytes32 destinationTranche = sourceTranche;
        TranchesManagerTokenModule tranchesManager;
        for (uint i = 0; i < tranchesManagers.length; i++) {
            tranchesManager = TranchesManagerTokenModule(tranchesManagers[i]);
            destinationTranche = tranchesManager.calculateDestinationTranche(destinationTranche, sourceTranche, from, amount, data);
        }
        return destinationTranche;
    }

    function canTransfer(bytes32 tranche, address operator, address from, address to, uint256 amount, bytes data)
    public view returns (byte result, string message, bytes32 destinationTranche)
    {
        destinationTranche = getDestinationTranche(tranche, to, amount, data);

        if (from != address(0) && amount > balancesPerTranche[from][tranche]) {
            return (0xA4, "Insufficient funds", destinationTranche);
        }

        result = 0xA0;
        message = transferValidators.length > 0 ? "Approved" : "Unrestricted";
        TransferValidatorTokenModule validator;

        // we need to go through all the transfer modules and check if we can send
        // if there are multiple errors, only the last one will be returned
        for (uint i = 0; i < transferValidators.length; i++) {
            validator = TransferValidatorTokenModule(transferValidators[i]);
            (result, message) = validator.validateTransfer(tranche, destinationTranche, operator, from, to, amount, data);
            if (result != 0xA0 && result != 0xA1 && result != 0xA2) {
                // there is an error or a forced transfer, so we will stop at this point
                break;
            }
        }
    }

    function transferByTranche(bytes32 tranche, address to, uint256 amount, bytes data)
    isReleased whenNotPaused
    public returns (bytes32)
    {
        require(to != address(0), "Cannot transfer to address 0x0");

        return internalTransferByTranche(tranche, address(0), msg.sender, to, amount, data);
    }

    function operatorTransferByTranche(bytes32 tranche, address from, address to, uint256 amount, bytes data)
    isReleased whenNotPaused
    public returns (bytes32)
    {
        require(isOperator(msg.sender), "Invalid operator");
        require(from != address(0), "Cannot transfer from address 0x0");

        return internalTransferByTranche(tranche, msg.sender, from, to, amount, data);
    }

    function internalTransferByTranche(bytes32 tranche, address operator, address from, address to, uint256 amount, bytes data)
    internal returns (bytes32)
    {
        require(amount <= balancesPerTranche[from][tranche], "Insufficient funds in tranche");
        require(to != address(0), "Cannot transfer to address 0x0");
        require(amount >= 0, "Amount cannot be negative");

        verifyCanTransferOrRevert(tranche, operator, from, to, amount, data);

        bytes32 destinationTranche = getDestinationTranche(tranche, to, amount, data);
        balancesPerTranche[from][tranche] = balancesPerTranche[from][tranche].sub(amount);
        balancesPerTranche[to][destinationTranche] = balancesPerTranche[to][destinationTranche].add(amount);
        // make sure that tranche is added to destination
        if (amount > 0) {
            Bytes32ArrayLib.addIfNotPresent(tranches[to], tranche);
        }
        // remove tranche if the balance is zero for the source
        if (balancesPerTranche[from][tranche] == 0) {
            Bytes32ArrayLib.removeValue(tranches[from], tranche);
        }
        // update global balances
        balances[from] = balances[from].sub(amount);
        balances[to] = balances[to].add(amount);

        // trigger events
        emit TransferByTranche(tranche, destinationTranche, operator, from, to, amount, data);
        emit Transfer(from, to, amount); // this is for compatibility with ERC-20

        // notify listeners
        notifyTransfer(tranche, destinationTranche, operator, from, to, amount, data);

        return destinationTranche;
    }

    function tranchesOf(address tokenHolder)
    public view returns (bytes32[])
    {
        return tranches[tokenHolder];
    }

    function issueByTranche(bytes32 tranche, address tokenHolder, uint256 amount, bytes data)
    isReleased whenNotPaused
    public
    {
        require(tokenHolder != address(0), "Cannot issue tokens to address 0x0");
        require(isOperator(msg.sender) || isModule(msg.sender), "Only default operators or module can do this");

        verifyCanTransferOrRevert(tranche, msg.sender, address(0), tokenHolder, amount, data);

        balancesPerTranche[tokenHolder][tranche] = balancesPerTranche[tokenHolder][tranche].add(amount);
        balances[tokenHolder] = balances[tokenHolder].add(amount);
        if (amount > 0) {
            Bytes32ArrayLib.addIfNotPresent(tranches[tokenHolder], tranche);
        }
        totalSupply = totalSupply.add(amount);

        emit IssuedByTranche(tranche, msg.sender, tokenHolder, amount, data);

        // notify listeners
        notifyTransfer(bytes32(0), tranche, msg.sender, address(0), tokenHolder, amount, data);
    }


    function burnByTranche(bytes32 tranche, address tokenHolder, uint256 amount, bytes data)
    isReleased whenNotPaused
    public
    {
        require(isOperator(msg.sender), "Invalid operator");
        require(tokenHolder != address(0), "Cannot burn tokens from address 0x0");
        require(amount <= balancesPerTranche[tokenHolder][tranche], "Insufficient funds in tranche");

        verifyCanTransferOrRevert(tranche, msg.sender, tokenHolder, address(0), amount, data);

        balancesPerTranche[tokenHolder][tranche] = balancesPerTranche[tokenHolder][tranche].sub(amount);
        if (balancesPerTranche[tokenHolder][tranche] == 0) {
            Bytes32ArrayLib.removeValue(tranches[tokenHolder], tranche);
        }
        // update global balances
        balances[tokenHolder] = balances[tokenHolder].sub(amount);
        // reduce total supply of tokens
        totalSupply = totalSupply.sub(amount);
        // trigger events
        emit BurnedByTranche(tranche, msg.sender, tokenHolder, amount, data);
        // notify listeners
        notifyTransfer(tranche, bytes32(0), msg.sender, tokenHolder, address(0), amount, data);
    }

    function verifyCanTransferOrRevert(bytes32 tranche, address operator, address from, address to, uint256 amount, bytes data)
    internal view
    {
        byte code;
        string memory message;

        (code, message, ) = canTransfer(tranche, operator, from, to, amount, data);

        if (code != 0xA0 && code != 0xA1 && code != 0xA2 && code != 0xAF) {
            revert(message);
        }
    }

    function notifyTransfer(bytes32 fromTranche, bytes32 toTranche, address operator, address from, address to, uint256 amount, bytes data)
    internal
    {
        TransferListenerTokenModule transferListener;
        for (uint i = 0; i < transferListeners.length; i++) {
            transferListener = TransferListenerTokenModule(transferListeners[i]);
            transferListener.transferDone(fromTranche, toTranche, operator, from, to, amount, data);
        }
    }
}


contract SecurityTokenFactory is Factory {
    function createInstance(string name, string symbol, uint8 decimals, address[] operators)
    public returns(address)
    {
        SecurityToken instance = new SecurityToken(name, symbol, decimals, operators);
        instance.transferOwnership(msg.sender);
        addInstance(instance);
        return instance;
    }
}