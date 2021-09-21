// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./DividendPayingToken.sol";
import "./SafeMath.sol";
import "./IterableMapping.sol";
import "./Ownable.sol";

contract Polkastream is ERC20, Ownable {
    using SafeMath for uint256;
    
    //Dividend Tracking & Processing
    bool private swapping;
    PolkastreamDividendTracker public dividendTracker;
    address public _dividendProcessingWallet = 0x53A9f417C11701A95c964081cbdCa5a4c61eb681;
    
    //Address's
    address public publicSale = 0x5a5E2777dD1e3ae0c39521fEb49012cA3845D48F;
    address public rewards = 0xEe9143f5Efc1bA0315aE0cADc148843e4D7920Ea;
    address public teamAndAdvisors = 0x0beF5f7E292fB8523256415941D097Aa479C1BA7;
    address public operations = 0x37ECAaFBc289dA731B81c81A4454B108beD425a4;
    address public communityGrants = 0xf353B8Bb584c75900090e7F5e4309706e79d5385;
    address public privateSale = 0x0F18A35beee3604bDAa28A45e299d166f037116A;
    address public charity = 0x8A4904c92eA3F6508f4b7bA26537BFe31B09A5ee;
    
    //Locking of team & rewards wallets & vesting definitons
    uint256 public immutable teamLockingPeriod = 180 days;
    uint256 public rewardWalletLockingPeriod = 180 days;
    uint256 public rewardWalletLockingExtension = 30 days;
    uint256 public immutable lockingStartTime;
    uint256 public immutable vestingBlock = 30 days;
    uint256 public rewardWalletLockExtension;
    uint256 public immutable vestingPercentage = 5;
    uint256 public immutable totalAmountVesting = 200000000 * (10**18);
    uint256 public vestedAmountTransferred;
    
    //Uint's ---> By default 300k gas used for processing
    uint256 public PSTRRewardsFee = 3;
    uint256 public burnFee = 1;
    uint256 public totalFees = PSTRRewardsFee.add(burnFee);
    uint256 public gasForProcessing = 300000;
    uint256 public constant initialSupply = 1000000000 * (10**18);
    uint256 public immutable maxBurnThreshold = initialSupply.div(2);
    uint256 public immutable maxTransferAmount = initialSupply.div(20);

     //Mappings ---> Map of address and their status for fee exclusion. 
    mapping (address => bool) private _isExcludedFromFees;
    mapping (address => bool) public _isBlacklisted;

    //Events
    event UpdateDividendTracker(address indexed newAddress, address indexed oldAddress);
    event ExcludeFromFees(address indexed account, bool isExcluded);
    event ExcludeMultipleAccountsFromFees(address[] accounts, bool isExcluded);
    event GasForProcessingUpdated(uint256 indexed newValue, uint256 indexed oldValue);

    constructor() public ERC20("Polkastream", "PSTR") {

    	dividendTracker = new PolkastreamDividendTracker();

        //Exclude from receiving dividends
        dividendTracker.excludeFromDividends(address(dividendTracker));
        dividendTracker.excludeFromDividends(address(this));
        dividendTracker.excludeFromDividends(owner());
        dividendTracker.excludeFromDividends(publicSale);
        dividendTracker.excludeFromDividends(rewards);
        dividendTracker.excludeFromDividends(teamAndAdvisors);
        dividendTracker.excludeFromDividends(operations);
        dividendTracker.excludeFromDividends(communityGrants);
        dividendTracker.excludeFromDividends(privateSale);
        dividendTracker.excludeFromDividends(charity);

        //Exclude from paying fees or having max transaction amount
        excludeFromFees(owner(), true);
        excludeFromFees(address(this), true);
        excludeFromFees(_dividendProcessingWallet, true);
        excludeFromFees(publicSale, true);
        excludeFromFees(rewards, true);
        excludeFromFees(teamAndAdvisors, true);
        excludeFromFees(operations, true);
        excludeFromFees(communityGrants, true);
        excludeFromFees(privateSale, true);
        excludeFromFees(charity, true);

        /*
            _mint is an internal function in ERC20.sol that is only called here,
            and CANNOT be called ever again
        */
        _mint(publicSale, initialSupply.mul(30).div(100)); //Mints 30% to the public sale address
        _mint(rewards, initialSupply.mul(25).div(100)); //Mints 25% to the rewards address
        _mint(teamAndAdvisors, initialSupply.mul(20).div(100)); //Mints 20% to the team and advisors address
        _mint(operations, initialSupply.mul(12).div(100)); //Mints 12% to the operations address
        _mint(communityGrants, initialSupply.mul(6).div(100)); //Mints 6% to the community grants address
        _mint(privateSale, initialSupply.mul(5).div(100)); //Mints 5% to the private sale address
        _mint(charity, initialSupply.mul(2).div(100)); //Mints 2% to the charity address
        
        //Sets the start time for locked tokens
        lockingStartTime = block.timestamp;
    }

    receive() external payable {

  	}
  	
    //Blacklist an address
    function blacklistAddress(address _toBeListed, bool _trueOrFalse) external onlyOwner {
        _isBlacklisted[_toBeListed] = _trueOrFalse;
    }
  	
  	//Sets the wallet address to bounce token dividends through for processing
  	function setDividendProcessingWallet(address payable wallet) external onlyOwner {
        _dividendProcessingWallet = wallet;
        dividendTracker.setDividendProcessingWallet(wallet);
    }
    
    //Returns true or false if the tokens in the reward wallet are unlocked
    function isRewardUnlocked() public view returns(bool) {
        return block.timestamp >= lockingStartTime.add(rewardWalletLockingPeriod);
    }
    
    //Returns true or false if the tokens in the team wallet are eligible for vesting and unlocked(subject to vesting)
    function isTeamUnlocked() public view returns(bool) {
        return block.timestamp >= lockingStartTime.add(teamLockingPeriod);
    }
    
    //Extends the reward wallet locking period if desired
    function extendRewardLocking() public onlyOwner {
        rewardWalletLockingPeriod = rewardWalletLockingPeriod.add(rewardWalletLockExtension);
    }
    
    //Returns the amount of available vested tokens to be withdrawn from the team wallet
    function totalVestedAvailable() public view returns(uint256) {
        uint256 _monthsElapsed = (block.timestamp.sub(lockingStartTime.add(teamLockingPeriod))).div(30 days);
        uint256 _amount = (totalAmountVesting.mul(5).mul(_monthsElapsed).div(100).sub(vestedAmountTransferred));
        return _amount;
    }
  	
  	//Sets the address of this contract in the dividend tracker. The dividend tracker uses this address to process rewards
  	function setPSTR(address _PSTR) public onlyOwner {
  	    dividendTracker.setPSTR(_PSTR);
  	}
  	
  	//Updates the dividend tracker. This function should only be called if you need to migrate trackers
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

    //Sets a boolean for an account of true or false to be excluded from fees. This function may be called to add or remove accounts from paying fees
    function excludeFromFees(address account, bool excluded) public onlyOwner {
        require(_isExcludedFromFees[account] != excluded, "Polkastream: Account is already the value of 'excluded'");
        _isExcludedFromFees[account] = excluded;

        emit ExcludeFromFees(account, excluded);
    }

    //Sets a boolean of true or false for multiple accounts to be excluded from fees
    function excludeMultipleAccountsFromFees(address[] calldata accounts, bool excluded) public onlyOwner {
        for(uint256 i = 0; i < accounts.length; i++) {
            _isExcludedFromFees[accounts[i]] = excluded;
        }

        emit ExcludeMultipleAccountsFromFees(accounts, excluded);
    }

    //Sets the fee percentage to be assesed for Polkastream dividends on transaction
    function setPSTRRewardsFee(uint256 value) external onlyOwner{
        PSTRRewardsFee = value;
        totalFees = PSTRRewardsFee.add(burnFee);
    }

    //Sets the fee percentage to be assesed and burned on transaction
    function setBurnFee(uint256 value) external onlyOwner{
        burnFee = value;
        totalFees = PSTRRewardsFee.add(burnFee);
    }

    //Updates the gas utilized for auto processing features. This is set to 300k by default and should only be called if you are getting out of gas errors
    function updateGasForProcessing(uint256 newValue) public onlyOwner {
        require(newValue >= 200000 && newValue <= 500000, "Polkastream: gasForProcessing must be between 200,000 and 500,000");
        require(newValue != gasForProcessing, "Polkastream: Cannot update gasForProcessing to same value");
        emit GasForProcessingUpdated(newValue, gasForProcessing);
        gasForProcessing = newValue;
    }

    //Returns a boolean of true or false if an account is excluded from fees
    function isExcludedFromFees(address account) public view returns(bool) {
        return _isExcludedFromFees[account];
    }

    //Returns a boolean of true or false if an account is excluded from dividends
	function excludeFromDividends(address account) external onlyOwner{
	    dividendTracker.excludeFromDividends(account);
	}

    //Returns the last index processed for iterable mapping
    function getLastProcessedIndex() external view returns(uint256) {
    	return dividendTracker.getLastProcessedIndex();
    }

    //Transfers tokens ---> see in function for further detail on what it does at each step of the transfer process
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
        
        //Checks if the sender is the team and advisors wallets. If so, requires that the transfer does not exceed the number of available vested tokens
        //Updates the number of vested tokens that have been sent ---> used to determine available balance for transfer
        if(_msgSender() == teamAndAdvisors) {
            require(isTeamUnlocked() == true, "Tokens are locked");
            require(totalVestedAvailable() != 0, "No tokens vested");
            require(amount <= totalVestedAvailable(), "Transfers exceeds amount vested");
            vestedAmountTransferred = vestedAmountTransferred.add(amount);
        }
        
        //Checks if the sender is the rewards wallet. If so, requires that the token locking period has elapsed.
        if(_msgSender() == rewards) {
            require(isRewardUnlocked() == true, "Tokens are locked");
        }

        bool takeFee = !swapping;

        //If any account belongs to _isExcludedFromFee account then remove the fee. If any account is not excluded from fees apply max transaction amount
        if(_isExcludedFromFees[from] || _isExcludedFromFees[to]) {
            takeFee = false;
        }
        
        //If an account is not excluded from fees, requires that the transfer amount does not exceed the maximum transfer amount
        if(!_isExcludedFromFees[from]) {
            require(amount <= maxTransferAmount, "Amount is larger than max per transaction limit");
        }

        if(takeFee) {
            
            //If the maximum burn threshold has not been met, determines fee split and burns the burn fee percentage ---> transfers the dividend fee percentage to holders
            if(totalSupply() >= maxBurnThreshold) {
        	    uint256 fees = amount.mul(totalFees).div(100);

        	    amount = amount.sub(fees);
        	
        	    uint256 burnPercentage = totalFees.div(burnFee);
        	    uint256 burnAmount = fees.div(burnPercentage);
        	    uint256 rewardAmount = fees.sub(burnAmount);

                super._transfer(from, address(this), burnAmount);
                super.transfer(_dividendProcessingWallet, rewardAmount);
            
                burnPSTRFee();
            
                sendPSTRDividends();
            
            } else 
            
            //If the maximum burn threshold has been met, transfers 100% of the total fees assesd to holders
            if(totalSupply() <= maxBurnThreshold) {
                uint256 fees = amount.mul(totalFees).div(100);
                
                amount = amount.sub(fees);
                
                super.transfer(_dividendProcessingWallet, fees);
                
                sendPSTRDividends();
            }
        }

        super._transfer(from, to, amount);

        //Populates the tokenholder map for use in dividend processing
        try dividendTracker.setBalance(payable(from), balanceOf(from)) {} catch {}
        try dividendTracker.setBalance(payable(to), balanceOf(to)) {} catch {}

    }

    //Burns tokens assesed from the burn fee
    function burnPSTRFee() private  {

        uint256 balanceForUse = super.balanceOf(address(this));
        super._burn(address(this), balanceForUse);
    }

    //Processes dividends to holders
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
    
    //Uints
    uint256 public lastProcessedIndex;
    uint256 public immutable minimumTokenBalanceForDividends;
    uint256 public totalHoldingsEligible;
        
    //Address's    
    address public PSTR;
    address payable _dividendProcessingWallet;
    
    //Mapping
    mapping (address => bool) public eligibleForDividends;
    mapping (address => bool) public excludedFromDividends;

    //Events
    event ExcludeFromDividends(address indexed account);

    constructor() public DividendPayingToken("Polkastream_Dividen_Tracker", "Polkastream_Dividend_Tracker") {
        minimumTokenBalanceForDividends = 200000 * (10**9); //must hold 200000+ tokens
    }
    
    //Sets the address of Polkastream for use in dividend processing
    function setPSTR(address _PSTR) external onlyOwner {
        PSTR = _PSTR;
    }

    //Sets the wallet address to bounce token dividends through for processing
    function setDividendProcessingWallet(address payable _wallet) external onlyOwner {
        _dividendProcessingWallet = _wallet;
    }

    //Overriding transfer function to throw error
    function _transfer(address, address, uint256) internal override {
        require(false, "Polkastream_Dividend_Tracker: No transfers allowed");
    }

    //Excludes an account from dividends
    function excludeFromDividends(address account) external onlyOwner {
    	require(!excludedFromDividends[account]);
    	excludedFromDividends[account] = true;

    	_setBalance(account, 0);
    	tokenHoldersMap.remove(account);

    	emit ExcludeFromDividends(account);
    }

    //Returns the last processed index for iterable mapping
    function getLastProcessedIndex() external view returns(uint256) {
    	return lastProcessedIndex;
    }

    //Returns the number of tokenholders
    function getNumberOfTokenHolders() external view returns(uint256) {
        return tokenHoldersMap.keys.length;
    }

    //Gets the information of an account
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

    //Gets the information of an account at an index in the map
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

    //Populates the tokenholder map
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
    
    //Populates a true or false boolean for an address's eligibility for dividends ---> updates the total tokens eligible for dividends
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

            //Populates a true or false boolean for an address's eligibility for dividends ---> updates the total tokens eligible for dividends
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
    
    //Distributes dividends to eligible holders
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

            //If an account is eligible, calculates dividend amount and transfers the amount to the account
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
