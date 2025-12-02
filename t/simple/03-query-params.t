use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;

# Test: Query parameter parsing in PAGI::Simple::Request

use PAGI::Simple::Request;

# Test 1: query() returns Hash::MultiValue
subtest 'query returns Hash::MultiValue' => sub {
    my $req = PAGI::Simple::Request->new({
        query_string => 'foo=bar&baz=qux',
    });

    my $query = $req->query;
    isa_ok($query, 'Hash::MultiValue');
};

# Test 2: Basic query parameter parsing
subtest 'basic query parsing' => sub {
    my $req = PAGI::Simple::Request->new({
        query_string => 'name=John&age=30',
    });

    is($req->query_param('name'), 'John', 'name param');
    is($req->query_param('age'), '30', 'age param');
};

# Test 3: Multiple values for same key
subtest 'multiple values' => sub {
    my $req = PAGI::Simple::Request->new({
        query_string => 'tags=perl&tags=web&tags=async',
    });

    # Single value returns first
    is($req->query_param('tags'), 'perl', 'query_param returns first value');

    # All values via query_params
    my $all_tags = $req->query_params('tags');
    is(ref $all_tags, 'ARRAY', 'query_params returns arrayref');
    is(scalar @$all_tags, 3, 'three tag values');
    is($all_tags->[0], 'perl', 'first tag');
    is($all_tags->[1], 'web', 'second tag');
    is($all_tags->[2], 'async', 'third tag');

    # Via Hash::MultiValue directly
    my @values = $req->query->get_all('tags');
    is(scalar @values, 3, 'get_all returns all values');
};

# Test 4: URL decoding
subtest 'URL decoding' => sub {
    my $req = PAGI::Simple::Request->new({
        query_string => 'name=John%20Doe&message=Hello%2C%20World%21',
    });

    is($req->query_param('name'), 'John Doe', 'space decoded from %20');
    is($req->query_param('message'), 'Hello, World!', 'comma and exclamation decoded');
};

# Test 5: Plus sign as space
subtest 'plus as space' => sub {
    my $req = PAGI::Simple::Request->new({
        query_string => 'search=hello+world&foo=bar+baz',
    });

    is($req->query_param('search'), 'hello world', 'plus converted to space');
    is($req->query_param('foo'), 'bar baz', 'plus in foo');
};

# Test 6: Empty query string
subtest 'empty query string' => sub {
    my $req = PAGI::Simple::Request->new({
        query_string => '',
    });

    my $query = $req->query;
    isa_ok($query, 'Hash::MultiValue');
    ok(!defined $req->query_param('anything'), 'missing param returns undef');

    my $empty_params = $req->query_params('anything');
    is(ref $empty_params, 'ARRAY', 'query_params returns arrayref');
    is(scalar @$empty_params, 0, 'empty arrayref for missing param');
};

# Test 7: Missing query string (undefined)
subtest 'missing query string' => sub {
    my $req = PAGI::Simple::Request->new({});

    my $query = $req->query;
    isa_ok($query, 'Hash::MultiValue');
    ok(!defined $req->query_param('test'), 'missing param returns undef');
};

# Test 8: Key without value
subtest 'key without value' => sub {
    my $req = PAGI::Simple::Request->new({
        query_string => 'flag&name=test&another',
    });

    is($req->query_param('flag'), '', 'key without value returns empty string');
    is($req->query_param('name'), 'test', 'key with value works');
    is($req->query_param('another'), '', 'another key without value');
};

# Test 9: Empty value
subtest 'empty value' => sub {
    my $req = PAGI::Simple::Request->new({
        query_string => 'name=&other=value',
    });

    is($req->query_param('name'), '', 'empty value returns empty string');
    is($req->query_param('other'), 'value', 'non-empty value works');
};

# Test 10: Special characters in key and value
subtest 'special characters' => sub {
    my $req = PAGI::Simple::Request->new({
        query_string => 'key%3Dname=value%26data&foo=bar%3Dbaz',
    });

    is($req->query_param('key=name'), 'value&data', 'encoded = and & in key/value');
    is($req->query_param('foo'), 'bar=baz', 'encoded = in value');
};

# Test 11: Unicode characters
subtest 'unicode' => sub {
    my $req = PAGI::Simple::Request->new({
        # UTF-8 encoded: name=日本語
        query_string => 'name=%E6%97%A5%E6%9C%AC%E8%AA%9E',
    });

    my $value = $req->query_param('name');
    # The bytes should be correctly decoded
    is(length($value), 9, 'nine bytes for Japanese characters');
};

# Test 12: Semicolon as separator (alternative to &)
subtest 'semicolon separator' => sub {
    my $req = PAGI::Simple::Request->new({
        query_string => 'a=1;b=2;c=3',
    });

    is($req->query_param('a'), '1', 'a param');
    is($req->query_param('b'), '2', 'b param');
    is($req->query_param('c'), '3', 'c param');
};

# Test 13: Mixed & and ; separators
subtest 'mixed separators' => sub {
    my $req = PAGI::Simple::Request->new({
        query_string => 'a=1&b=2;c=3&d=4',
    });

    is($req->query_param('a'), '1', 'a param');
    is($req->query_param('b'), '2', 'b param');
    is($req->query_param('c'), '3', 'c param');
    is($req->query_param('d'), '4', 'd param');
};

# Test 14: Query object is cached
subtest 'query caching' => sub {
    my $req = PAGI::Simple::Request->new({
        query_string => 'foo=bar',
    });

    my $query1 = $req->query;
    my $query2 = $req->query;

    is($query1, $query2, 'query object is cached');
};

# Test 15: Case-sensitive parameter names
subtest 'case sensitive params' => sub {
    my $req = PAGI::Simple::Request->new({
        query_string => 'Name=John&name=jane&NAME=BOB',
    });

    is($req->query_param('Name'), 'John', 'Name (capital N)');
    is($req->query_param('name'), 'jane', 'name (lowercase)');
    is($req->query_param('NAME'), 'BOB', 'NAME (all caps)');
};

done_testing;
