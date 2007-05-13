use Test::More tests => 14;

BEGIN {
	delete $ENV{PERL_DL_NONLAZY};
	use_ok( 'IPC::Messaging' );
}

# got syntax
eval { got 1,2,3; };
like($@||"", qr/"got" outside "receive"/, "got outside receive");
eval { receive { got }; };
like($@||"", qr/not enough arguments/, "got: not enough args");
eval { receive { got 1,2 }; };
like($@||"", qr/missing "then"/, "got: missing then");
eval { receive { got [],1,then {} }; };
like($@||"", qr/arrayref not by itself/, "arrayref not by itself");
eval { receive { got [],then {} }; };
like($@||"", qr/missing message name/, "missing message name");
eval { receive { got [[]],then {} }; };
like($@||"", qr/message name must not be a ref/, "message name must not be a ref");
eval { receive { got n=>{},1,then {} }; };
like($@||"", qr/unexpected hashref/, "unexpected hashref");
eval { receive { got n=>1,then {} }; };
like($@||"", qr/odd number of matching elements/, "odd number of matching elements");

# then syntax
eval { then {}; };
like($@||"", qr/"then" outside "receive"/, "then outside receive");

# after syntax
eval { after 1,2; };
like($@||"", qr/"after" outside "receive"/, "after outside receive");
eval { receive { after 1,2 }; };
like($@||"", qr/missing "then"/, "after: missing then");
eval { receive { after 1,then{}; after 2,then{}; }; };
like($@||"", qr/duplicate "after"/, "duplicate after");

# receive syntax
eval { receive { then {} } };
like($@||"", qr/dangling "then"/, "dangling then");
