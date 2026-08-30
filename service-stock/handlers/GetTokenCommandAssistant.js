var GetTokenCommandAssistant = Class.create({
					
	run: function(future){
		var dbService = new PalmProfileDBService();
		var dbFuture = dbService.getAccountToken();
		
		dbFuture.then(function () {
            return PalmProfileUtil.handleThenResult(this, "GetTokenCommandAssistant", future, dbFuture, function(){
				if (dbFuture.result.results.length === 0) {
					PalmProfileUtil.sendError(future, "NO_TOKEN", "Token could not be fetched");
				} else {
					
					var result = dbFuture.result.results[0];
					
					if (result.token) { // it can be undefined!
						future.result = {
							"accountAlias": result.alias,
							"token": result.token,
							"accountState": result.state,
							"uniqueId": result.uniqueId,
							"jabberId": result.jabberId,
							"randomAttribute" : result.randomAttribute
						};
					} else {
						PalmProfileUtil.sendError(future, "NO_TOKEN", "Token could not be fetched");
					}
				}
			});	
		});	
	}
	
});