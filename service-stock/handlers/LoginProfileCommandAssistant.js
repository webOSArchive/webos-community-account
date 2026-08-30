var LoginProfileCommandAssistant = Class.create({
					
	run: function(future){
		this.args = this.controller.args;
		
		if(this.validateRequest() === false) {
			PalmProfileUtil.sendError (future, "INVALID_REQUEST", "One or more request params are missing");
			return;
		}
		
		//calling isEmailAvailable will update the LCN endpoints
		ServiceLog.log("---------- checkingLCN ---------");
		var accountFuture = PalmCall.call("palm://com.palm.accountservices/", "isEmailAvailable", {email: this.args.email});  
		accountFuture.then(this, function() { 
            if(accountFuture.exception) {
				this.checkLCNRetry (future);
            } else {
				this.getDeviceProfile (future);
			}
		});
	},
	
	validateRequest: function () {
		if(!(this.args.email) || !(this.args.password) || !(this.args.application)) {
			return false;	
		}
		return true;
	},

	checkLCNRetry: function (future) {
		//calling isEmailAvailable will update the LCN endpoints
		var accountFuture = PalmCall.call("palm://com.palm.accountservices/", "isEmailAvailable", {email: this.args.email});  
		accountFuture.then(this, function() { 
            if(accountFuture.exception) {
				PalmProfileUtil.sendError(future, accountFuture.exception.errorCode, accountFuture.exception.errorText);
            } else {
				this.getDeviceProfile (future);
			}
		});
	},
	
	getDeviceProfile: function (future) {
		var profileFuture = PalmCall.call("palm://com.palm.deviceprofile/", "getDeviceProfile", {});	
		profileFuture.then(this, function() { 
          return PalmProfileUtil.handleThenResult(this, "getDeviceProfile", future, profileFuture, function(){
				var result = profileFuture.result;
				ServiceLog.log("Got device profile");
				if(result.returnValue && result.returnValue === true) {
					// Convert device props into the format that the server expects
					var info = result.deviceInfo;
					ServiceLog.log("Got device profile: ---- info -----"+info);
					this.authenticateProfile(future, info);
					return;
				}
				PalmProfileUtil.sendError(future, "DEVICE_PROFILE_ERROR", "Could not read device profile");
			});	
		});	
	},
	
	authenticateProfile: function (future, info) {
		var deviceParams = "";
		try {
			deviceParams = PalmProfileUtil.getDeviceParams(info);
		} catch (e) {
			PalmProfileUtil.sendError("DEVICE_PROFILE_ERROR", "Could not read device profile");
			return;
		}	
					
		var romTokens = "";
		try {
			romTokens = PalmProfileUtil.getROMTokens (info);
		} catch (e) {	
			PalmProfileUtil.sendError("DEVICE_PROFILE_ERROR", "Could not read device profile");
			return;
		}
		
		var acctParams = this.getAccountParams(deviceParams, romTokens);
		this.sendRequestToServer (future, acctParams);
	},
	
	getAccountParams: function (deviceParams, romTokens) {
		var accountParams = {
			"InAuthenticateFromDevice": {
				"application": this.args.application,
				"accountAlias": this.args.email,
				"password": this.args.password,
				"device": deviceParams,
				"romToken": romTokens
			}	
		};
		return accountParams;
	},
	
	sendRequestToServer: function (future, acctParams) {
		var profileFuture =  PalmProfileUtil.postRequest("authenticateFromDevice", acctParams, future, "ACCOUNT_CREATION_ERROR");
		profileFuture.then(this, function() { 
	        return PalmProfileUtil.handleThenResult(this, "authenticateFromDevice", future, profileFuture, function(){
				var result = profileFuture.result.responseJSON;
				
				if(result.AuthenticateInfoEx) {
					ServiceLog.log("---------- profileFuture result ---------"+JSON.stringify(result.AuthenticateInfoEx));
					PalmProfileUtil.saveAccountToken (result.AuthenticateInfoEx, future, "ACCOUNT_CREATION_ERROR");
					return;
				}
							
				PalmProfileUtil.sendError(future, "LOGIN_ERROR", "Can't sign in to profile");
			}); 
		}); 
	},
		
});