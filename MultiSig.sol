// SPDX-License-Identifier: MIT
pragma solidity ^0.4.0;

contract MultiSigWallet {
    uint256 public m_required;
    uint256 public m_numOwners;
    mapping(address => uint256) public owners;
    mapping(bytes32 => Transaction) public transactions;
    mapping(uint256 => bytes32) public transactionList;
    uint256 public m_dailyLimit;
    uint256 public spentToday;
    uint256 public lastDay;
    uint8 public version;
    
    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        uint256 confirmations;
        uint256 createdBlock;
    }

    event Confirmation(address indexed owner, bytes32 indexed operation);
    event Revoke(address indexed owner, bytes32 indexed operation);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event OwnerAdded(address indexed newOwner);
    event OwnerRemoved(address indexed oldOwner);
    event Deposit(address indexed sender, uint256 value);
    event SingleTransact(address indexed owner, uint256 value, address to, bytes data);
    event MultiTransact(address indexed owner, bytes32 indexed operation, uint256 value, address to, bytes data);
    event ConfirmationNeeded(bytes32 indexed operation, address initiator, uint256 value, address to, bytes data);
    event RequirementChanged(uint256 newRequirement);

    modifier onlyOwner() {
        require(owners[msg.sender] > 0);
        _;
    }

    function MultiSigWallet(uint256 _required, address[] _owners) public {
        m_required = _required;
        m_numOwners = _owners.length;
        for (uint256 i = 0; i < _owners.length; i++) {
            owners[_owners[i]] = i + 1;
        }
    }

    function() public payable {
        if (msg.value > 0) {
            emit Deposit(msg.sender, msg.value);
        }
    }

    function kill(address _to) public onlyOwner {
        selfdestruct(_to);
    }

    function isOwner(address _owner) public view returns (bool) {
        return owners[_owner] > 0;
    }

    function hasConfirmed(bytes32 _operation, address _owner) public view returns (bool) {
        return (owners[_owner] > 0 && (transactions[_operation].confirmations & (2 ** owners[_owner])) != 0);
    }

    function revoke(bytes32 _operation) public onlyOwner {
        Transaction storage t = transactions[_operation];
        uint256 ownerIndexBit = 2 ** owners[msg.sender];
        if ((t.confirmations & ownerIndexBit) != 0) {
            t.confirmations -= ownerIndexBit;
            emit Revoke(msg.sender, _operation);
        }
    }

    function confirm(bytes32 _h) public onlyOwner returns (bool) {
        if (transactions[_h].createdBlock == 0) {
            transactions[_h] = Transaction({
                to: 0,
                value: 0,
                data: "",
                confirmations: 0,
                createdBlock: block.number
            });
            transactionList[transactionList.length] = _h;
        }

        if ((transactions[_h].confirmations & (2 ** owners[msg.sender])) == 0) {
            transactions[_h].confirmations |= 2 ** owners[msg.sender];
            emit Confirmation(msg.sender, _h);
            if (transactions[_h].confirmations >= m_required) {
                executeTransaction(_h);
                return true;
            }
        }
        return false;
    }

    function executeTransaction(bytes32 _h) internal {
        Transaction storage t = transactions[_h];
        if (t.to != address(0)) {
            if (t.data.length == 0) {
                require(t.to.call.value(t.value)());
            } else {
                require(t.to.call.value(t.value)(t.data));
            }
            emit MultiTransact(msg.sender, _h, t.value, t.to, t.data);
        }
        delete transactions[_h];
    }

    function setDailyLimit(uint256 _newLimit) public onlyOwner {
        m_dailyLimit = _newLimit;
        emit RequirementChanged(m_dailyLimit);
    }

    function resetSpentToday() public onlyOwner {
        if (block.timestamp > lastDay + 24 hours) {
            spentToday = 0;
            lastDay = block.timestamp;
        }
    }

    function changeRequirement(uint256 _newRequired) public onlyOwner {
        require(_newRequired <= m_numOwners);
        m_required = _newRequired;
        emit RequirementChanged(m_required);
    }

    function addOwner(address _owner) public onlyOwner {
        require(owners[_owner] == 0);
        m_numOwners++;
        owners[_owner] = m_numOwners;
        emit OwnerAdded(_owner);
    }

    function removeOwner(address _owner) public onlyOwner {
        require(owners[_owner] > 0);
        uint256 ownerIndex = owners[_owner];
        owners[_owner] = 0;
        for (uint256 i = ownerIndex; i < m_numOwners; i++) {
            owners[owners[i]] = i;
        }
        m_numOwners--;
        if (m_required > m_numOwners) {
            m_required = m_numOwners;
        }
        emit OwnerRemoved(_owner);
    }

    function changeOwner(address _from, address _to) public onlyOwner {
        require(owners[_from] > 0 && owners[_to] == 0);
        owners[_to] = owners[_from];
        owners[_from] = 0;
        emit OwnerChanged(_from, _to);
    }

    function execute(address _to, uint256 _value, bytes _data) public onlyOwner returns (bytes32) {
        if (spentToday + _value > m_dailyLimit) {
            bytes32 operation = keccak256(abi.encodePacked(_to, _value, _data, block.number));
            if (confirm(operation)) {
                return operation;
            } else {
                transactions[operation] = Transaction({
                    to: _to,
                    value: _value,
                    data: _data,
                    confirmations: 0,
                    createdBlock: block.number
                });
                emit ConfirmationNeeded(operation, msg.sender, _value, _to, _data);
                return operation;
            }
        } else {
            spentToday += _value;
            require(_to.call.value(_value)(_data));
            emit SingleTransact(msg.sender, _value, _to, _data);
        }
    }
}
