// Our account-setup app shows the Terms card then the sign-in card. FirstUse.config
// drives the firstuse scene sequence; with the safe-completion patch in
// FirstUse.js.patch this means: accept our community TOS (Palm.js.patch fetches it
// from device.php?m=getTermsAndConditions) -> sign in -> write account -> confirm page.
FirstUse.config = [
	{name: "palm", requires:{data: true}},
	{name: "signin", requires:{data: true}},
];
