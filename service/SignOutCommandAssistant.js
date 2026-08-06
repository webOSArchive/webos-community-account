/* webOS Archive — not part of HP's webOS.
 *
 * palm://com.palm.accountservices/signOut {}
 *
 * Signs this device out: revokes the account token on the server, then clears it
 * from the local db8 profile.
 *
 * Deliberately NOT the stock dissociateCurrentDevice, which posts HP's
 * dissociateAccountFromDevice and then leaves the local profile fully intact —
 * i.e. it detaches server-side while the device still believes it is signed in,
 * which is the worst of both.
 *
 * Two deliberate choices:
 *
 * 1. The local clear happens even when the server call fails. The user asked to
 *    sign out; refusing because the device is offline would strand them signed in
 *    with no way out. The response reports serverTokenRevoked so a caller can say
 *    so, and the stranded token can still be revoked from another device once
 *    "remove this device" exists.
 *
 * 2. The local ACCOUNT record is left in place and only its token is cleared.
 *    Deleting it would be the true inverse of createLocalAccount, but
 *    com.palm.app.accounts reads palmProfileAccount.username/.icon unguarded in
 *    onAccountsAvailable, so removing the record outright breaks the Accounts app
 *    on the next launch. Clearing the token is enough for everything that matters:
 *    getAccountToken then fails, which is what the Accounts app's capability probe
 *    and the webOS Account app's launch probe both key off.
 */
var SignOutCommandAssistant = Class.create({

	run: function (future) {
		var dbService = new PalmProfileDBService();
		var dbFuture = dbService.getAccountToken();

		dbFuture.then(this, function () {
			var token = null;
			try {
				var results = dbFuture.result && dbFuture.result.results;
				if (results && results.length > 0) { token = results[0].token; }
			} catch (e) {
				ServiceLog.log("signOut: could not read the local profile: " + e);
			}

			if (!token) {
				// Already signed out. Idempotent rather than an error: a caller
				// retrying after a half-finished sign-out should succeed.
				future.result = { "returnValue": true, "serverTokenRevoked": false };
				return;
			}
			this.revokeOnServer(future, token);
		});
	},

	revokeOnServer: function (future, token) {
		// device.php?m=deauthenticate — takes {token}, idempotent, always 200.
		var f = PalmProfileUtil.postRequest("deauthenticate", { "token": token }, future, "SIGNOUT_ERROR");
		f.then(this, function () {
			var revoked = false;
			// Not handleThenResult: that aborts the whole command on a server
			// error, and here a server error must NOT stop the local sign-out.
			try {
				var r = f.result;
				revoked = !!(r && r.responseJSON && r.responseJSON.deauthenticated);
			} catch (e) {
				ServiceLog.log("signOut: server revoke failed, clearing locally anyway: " + e);
			}
			this.clearLocalToken(future, revoked);
		});
	},

	clearLocalToken: function (future, revoked) {
		var done = function () {
			future.result = { "returnValue": true, "serverTokenRevoked": revoked };
		};
		try {
			var dbService = new PalmProfileDBService();
			// Blank the fields that say "signed in". The record itself stays; the
			// next sign-in upserts over it (see createLocalAccount).
			var dbFuture = dbService.updateProfile({
				"token": "", "alias": "", "state": "", "uniqueId": "", "username": ""
			});
			dbFuture.then(this, function () {
				try { dbFuture.result; } catch (e) {
					ServiceLog.log("signOut: db8 clear reported an error: " + e);
				}
				done();
			});
		} catch (e) {
			// Never leave the command unresolved — a hung sign-out is worse than a
			// reported partial one.
			ServiceLog.log("signOut: could not clear the local token: " + e);
			done();
		}
	}
});
