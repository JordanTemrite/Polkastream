// SPDX-License-Identifier: MIT

pragma solidity ^0.6.2;

import "./DividendPayingToken.sol";
import "./SafeMath.sol";
import "./IterableMapping.sol";
import "./Ownable.sol";

contract Polkastream is ERC20, Ownable {
    using SafeMath for uint256;

    bool private swapping;

    PolkastreamDividendTracker public dividendTracker;

    address public deadWallet = 0x000000000000000000000000000000000000dEaD;
    
    address public _dividendProcessingWallet = 0xB14601EF238417d347Dc7DB1d236411588392774;
    
    mapping(address => bool) public _isBlacklisted;

    uint256 public PSTRRewardsFee = 3;
    uint256 public burnFee = 1;
    uint256 public totalFees = PSTRRewardsFee.add(burnFee);


    // use by default 300,000 gas to process auto-claiming dividends
    uint256 public gasForProcessing = 300000;

     // exlcude from fees and max transaction amount
    mapping (address => bool) private _isExcludedFromFees;

    event UpdateDividendTracker(address indexed newAddress, address indexed oldAddress);

    event ExcludeFromFees(address indexed account, bool isExcluded);
    event ExcludeMultipleAccountsFromFees(address[] accounts, bool isExcluded);

    event GasForProcessingUpdated(uint256 indexed newValue, uint256 indexed oldValue);

    constructor() public ERC20("Polkastream", "PSTR") {

    	dividendTracker = new PolkastreamDividendTracker();

        // exclude from receiving dividends
        dividendTracker.excludeFromDividends(address(dividendTracker));
        dividendTracker.excludeFromDividends(address(this));
        dividendTracker.excludeFromDividends(owner());
        dividendTracker.excludeFromDividends(deadWallet);

        // exclude from paying fees or having max transaction amount
        excludeFromFees(owner(), true);
        excludeFromFees(address(this), true);
        excludeFromFees(_dividendProcessingWallet, true);

        /*
            _mint is an internal function in ERC20.sol that is only called here,
            and CANNOT be called ever again
        */
        _mint(owner(), 100000000000 * (10**18));
    }

    receive() external payable {

  	}
  	
  	function setDividendProcessingWallet(address payable wallet) external onlyOwner {
        _dividendProcessingWallet = wallet;
        dividendTracker.setDividendProcessingWallet(wallet);
    }
  	
  	function setPSTR(address _PSTR) public onlyOwner {
  	    dividendTracker.setPSTR(_PSTR);
  	}
  	
    function updateDividendTracker(address newAddress) public onlyOwner {
        require(newAddress != address(dividendTracker), "Polkastream: The dividend tracker already has that address");

        PolkastreamDividendTracker newDividendTracker = PolkastreamDividendTracker(payable(newAddress));

        require(newDividendTracker.owner() == address(this), "Polkastream: The new dividend tracker must be owned by the Polkastream token contract");

        newDividendTracker.excludeFromDividends(address(newDividendTracker));
        newDividendTracker.excludeFromDividends(address(this));
        newDividendTracker.excludeFromDividends(owner());

        emit UpdateDividendTracker(newAddress, address(dividendTracker));

        dividendTracker = newDividendTracker;
    }

    function excludeFromFees(address account, bool excluded) public onlyOwner {
        require(_isExcludedFromFees[account] != excluded, "Polkastream: Account is already the value of 'excluded'");
        _isExcludedFromFees[account] = excluded;

        emit ExcludeFromFees(account, excluded);
    }

    function excludeMultipleAccountsFromFees(address[] calldata accounts, bool excluded) public onlyOwner {
        for(uint256 i = 0; i < accounts.length; i++) {
            _isExcludedFromFees[accounts[i]] = excluded;
        }

        emit ExcludeMultipleAccountsFromFees(accounts, excluded);
    }

    function setPSTRRewardsFee(uint256 value) external onlyOwner{
        PSTRRewardsFee = value;
        totalFees = PSTRRewardsFee.add(burnFee);
    }

    function setBurnFee(uint256 value) external onlyOwner{
        burnFee = value;
        totalFees = PSTRRewardsFee.add(burnFee);
    }

    function updateGasForProcessing(uint256 newValue) public onlyOwner {
        require(newValue >= 200000 && newValue <= 500000, "Polkastream: gasForProcessing must be between 200,000 and 500,000");
        require(newValue != gasForProcessing, "Polkastream: Cannot update gasForProcessing to same value");
        emit GasForProcessingUpdated(newValue, gasForProcessing);
        gasForProcessing = newValue;
    }

    function isExcludedFromFees(address account) public view returns(bool) {
        return _isExcludedFromFees[account];
    }

	function excludeFromDividends(address account) external onlyOwner{
	    dividendTracker.excludeFromDividends(account);
	}

    function getLastProcessedIndex() external view returns(uint256) {
    	return dividendTracker.getLastProcessedIndex();
    }

    function getNumberOfDividendTokenHolders() external view returns(uint256) {
        return dividendTracker.getNumberOfTokenHolders();
    }


    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(!_isBlacklisted[from] && !_isBlacklisted[to], 'Blacklisted address');

        if(amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        bool takeFee = !swapping;

        // if any account belongs to _isExcludedFromFee account then remove the fee
        if(_isExcludedFromFees[from] || _isExcludedFromFees[to]) {
            takeFee = false;
        }

        if(takeFee) {
        	uint256 fees = amount.mul(totalFees).div(100);

        	amount = amount.sub(fees);
        	
        	uint256 burnPercentage = totalFees.div(burnFee);
        	uint256 burnAmount = fees.div(burnPercentage);
        	uint256 rewardAmount = fees.sub(burnAmount);

            super._transfer(from, address(this), burnAmount);
            super.transfer(_dividendProcessingWallet, rewardAmount);
            
            burnPSTRFee();
            
            sendPSTRDividends();
            
        }

        super._transfer(from, to, amount);

        try dividendTracker.setBalance(payable(from), balanceOf(from)) {} catch {}
        try dividendTracker.setBalance(payable(to), balanceOf(to)) {} catch {}

    }

    function burnPSTRFee() private  {

        uint256 balanceForUse = super.balanceOf(address(this));
        super._burn(address(this), balanceForUse);
    }

    function sendPSTRDividends() private {
        dividendTracker.populateDividends(gasForProcessing);
        dividendTracker.distributeDividends(gasForProcessing);
    }
}

contract PolkastreamDividendTracker is Ownable, DividendPayingToken {
    using SafeMath for uint256;
    using SafeMathInt for int256;
    using IterableMapping for IterableMapping.Map;

    IterableMapping.Map private tokenHoldersMap;
    uint256 public lastProcessedIndex;
    
    address public PSTR;
    
    uint256 public totalHoldingsEligible;
    
    address payable _dividendProcessingWallet;
    
    mapping (address => bool) public eligibleForDividends;

    mapping (address => bool) public excludedFromDividends;

    uint256 public immutable minimumTokenBalanceForDividends;

    event ExcludeFromDividends(address indexed account);

    constructor() public DividendPayingToken("Polkastream_Dividen_Tracker", "Polkastream_Dividend_Tracker") {
        minimumTokenBalanceForDividends = 200000 * (10**18); //must hold 200000+ tokens
    }
    
    function setPSTR(address _PSTR) external onlyOwner {
        PSTR = _PSTR;
    }

    function setDividendProcessingWallet(address payable _wallet) external onlyOwner {
        _dividendProcessingWallet = _wallet;
    }

    function _transfer(address, address, uint256) internal override {
        require(false, "Polkastream_Dividend_Tracker: No transfers allowed");
    }

    function excludeFromDividends(address account) external onlyOwner {
    	require(!excludedFromDividends[account]);
    	excludedFromDividends[account] = true;

    	_setBalance(account, 0);
    	tokenHoldersMap.remove(account);

    	emit ExcludeFromDividends(account);
    }

    function getLastProcessedIndex() external view returns(uint256) {
    	return lastProcessedIndex;
    }

    function getNumberOfTokenHolders() external view returns(uint256) {
        return tokenHoldersMap.keys.length;
    }

    function getAccount(address _account)
        public view returns (
            address account,
            int256 index,
            int256 iterationsUntilProcessed) {
        account = _account;

        index = tokenHoldersMap.getIndexOfKey(account);

        iterationsUntilProcessed = -1;

        if(index >= 0) {
            if(uint256(index) > lastProcessedIndex) {
                iterationsUntilProcessed = index.sub(int256(lastProcessedIndex));
            }
            else {
                uint256 processesUntilEndOfArray = tokenHoldersMap.keys.length > lastProcessedIndex ?
                                                        tokenHoldersMap.keys.length.sub(lastProcessedIndex) :
                                                        0;


                iterationsUntilProcessed = index.add(int256(processesUntilEndOfArray));
            }
        }

    }

    function getAccountAtIndex(uint256 index)
        public view returns (
            address,
            int256,
            int256) {
    	if(index >= tokenHoldersMap.size()) {
            return (0x0000000000000000000000000000000000000000, -1, -1);
        }

        address account = tokenHoldersMap.getKeyAtIndex(index);

        return getAccount(account);
    }

    function setBalance(address payable account, uint256 newBalance) external onlyOwner {
    	if(excludedFromDividends[account]) {
    		return;
    	}else 

    	if(newBalance >= minimumTokenBalanceForDividends) {
    		tokenHoldersMap.set(account, 0);
    	}
    	else {
    		tokenHoldersMap.remove(account);
    	}

    }
    
    function populateDividends(uint256 gas) public returns (uint256, uint256, uint256) {
    	uint256 numberOfTokenHolders = tokenHoldersMap.keys.length;

    	if(numberOfTokenHolders == 0) {
    		return (0, 0, lastProcessedIndex);
    	}

    	uint256 _lastProcessedIndex = lastProcessedIndex;

    	uint256 gasUsed = 0;

    	uint256 gasLeft = gasleft();

    	uint256 iterations = 0;
    	uint256 claims = 0;

    	while(gasUsed < gas && iterations < numberOfTokenHolders) {
    		_lastProcessedIndex++;

    		if(_lastProcessedIndex >= tokenHoldersMap.keys.length) {
    			_lastProcessedIndex = 0;
    		}

    		address account = tokenHoldersMap.keys[_lastProcessedIndex];

            if(IERC20(PSTR).balanceOf(account) < minimumTokenBalanceForDividends && eligibleForDividends[account] == true) {
                eligibleForDividends[account] = false;
            } else
            if(IERC20(PSTR).balanceOf(account) >= minimumTokenBalanceForDividends && excludedFromDividends[account] != true) {
                uint256 eligibleBalance = IERC20(PSTR).balanceOf(account);
                eligibleForDividends[account] = true;
                totalHoldingsEligible = totalHoldingsEligible.add(eligibleBalance);
            }
            
    		iterations++;

    		uint256 newGasLeft = gasleft();

    		if(gasLeft > newGasLeft) {
    			gasUsed = gasUsed.add(gasLeft.sub(newGasLeft));
    		}

    		gasLeft = newGasLeft;
    	}

    	lastProcessedIndex = _lastProcessedIndex;

    	return (iterations, claims, lastProcessedIndex);
    }
    
    function distributeDividends(uint256 gas) public returns (uint256, uint256, uint256) {
    	uint256 numberOfTokenHolders = tokenHoldersMap.keys.length;

    	if(numberOfTokenHolders == 0) {
    		return (0, 0, lastProcessedIndex);
    	}

    	uint256 _lastProcessedIndex = lastProcessedIndex;

    	uint256 gasUsed = 0;

    	uint256 gasLeft = gasleft();

    	uint256 iterations = 0;
    	uint256 claims = 0;

    	while(gasUsed < gas && iterations < numberOfTokenHolders) {
    		_lastProcessedIndex++;

    		if(_lastProcessedIndex >= tokenHoldersMap.keys.length) {
    			_lastProcessedIndex = 0;
    		}

    		address account = tokenHoldersMap.keys[_lastProcessedIndex];

            if(eligibleForDividends[account] == true && totalHoldingsEligible != 0) {
                uint256 tokensAvailable = IERC20(PSTR).balanceOf(_dividendProcessingWallet);
                uint256 userBalance = IERC20(PSTR).balanceOf(account);
                uint256 userShare = totalHoldingsEligible.div(userBalance);
                uint256 userDividendAmount = tokensAvailable.div(userShare);
                IERC20(PSTR).transferFrom(_dividendProcessingWallet, account, userDividendAmount);
            }
            
    		iterations++;

    		uint256 newGasLeft = gasleft();

    		if(gasLeft > newGasLeft) {
    			gasUsed = gasUsed.add(gasLeft.sub(newGasLeft));
    		}

    		gasLeft = newGasLeft;
    	}

    	lastProcessedIndex = _lastProcessedIndex;
    	
    	totalHoldingsEligible = 0;

    	return (iterations, claims, lastProcessedIndex);
    }
}
