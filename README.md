# NAME

Stash::REST - Add Requests into stash. Then, Extends with Class::Trigger!

# SYNOPSIS

    use Stash::REST;

    $obj = Stash::REST->new(
        do_request => sub {
            my $req = shift;

            # in case of testings

            my ($res, $c) = ctx_request($req);
            return $res;

            # in case of using LWP
            $req->uri( 'http://your-api.com' );
            return LWP::UserAgent->new->request($req);

        },
    );

    # you can write/read stash anytime
    $obj->stash('foo') # returns undef

    $obj->stash->{'foo'} = 3;

    $obj->stash('foo') # returns 3


    $obj->rest_post(
        '/zuzus',
        name  => 'add zuzu', # you can send fields for your custom on extensions.
        list  => 1,
        stash => 'easyname',
        prepare_request => sub {
            is(ref $_[0], 'HTTP::Request', 'HTTP::Request recived on prepare_request');
            $run++;
        },
        [ name => 'foo', ]
    );
    is($run, '2', '2 executions of prepare_request');

    $obj->stash->{'easyname'} # parsed response for POST /zuzus
    $obj->stash->{'easyname.id'} # HashRef->{id} if exists, from POST response.
    $obj->stash->{'easyname.get'} # parsed response of GET /zuzus/1 (from Location)

    if list => 1 is passed:
    $obj->stash->{'easyname.list'} # parsed response for GET '/zuzus'
    $obj->stash->{'easyname.url'} # 'zuzus/1'
    $obj->stash->{'easyname.list-url'} # '/zuzus'


    # this
    $obj->stash_ctx(
        'easyname.get',
        sub {
            my ($me) = @_;
        }
    );

    # equivalent to
    my $me = $c->stash->{'easyname.get'};


    # can be useful for testing/context isolation
    $obj->stash_ctx(
        'easyname.list',
        sub {
            my ($me) = @_;

            ok( $me = delete $me->{zuzus}, 'zuzu list exists' );

            is( @$me, 1, '1 zuzu' );

            is( $me->[0]{name}, 'foo', 'listing ok' );
        }
    );

    $obj->rest_put(
        $obj->stash('easyname.url'),
        name => 'update zuzu',
        [ new_option => 'new value' ]
    );

    $obj->rest_reload('easyname');

    $obj->stash_ctx(
        'easyname.get',
        sub {
            my ($me) = @_;

            is( $me->{name}, 'AAAAAAAAA', 'name updated!' );
        }
    );

    $obj->rest_delete( $obj->stash('easyname.url') );

    # reload expecting a different code.
    $obj->rest_reload( 'easyname', code => 404 );

    $obj->rest_reload_list('easyname');

    # HEAD return $res instead of parsed response
    my $res = $obj->rest_head(
        $obj->stash('easyname.url'),
    );
    is($res->headers->header('foo'), '1', 'header is present');

# DESCRIPTION

Stash::REST helps you use HTTP::Request::Common to create requests and put responses into a stash for futher user.

The main objective is to encapsulate the most used HTTP methods and expected response codes for future
extensions and analysis by other modules, using the callbacks [Class::Trigger](https://metacpan.org/pod/Class::Trigger).

# METHODS

## rest\_get

Same as:

    $self->rest_post(
        $url,
        code => 200,
        %conf,
        method => 'GET',
        $data
    );

## rest\_put

Same as:

    $self->rest_post(
        $url,
        code => ( exists $conf{is_fail} ? 400 : 202 ),
        %conf,
        method => 'PUT',
        $data
    );

## rest\_head

Same as:

    $self->rest_post(
        $url,
        code => 200,
        %conf,
        method => 'HEAD',
        $data
    );

## rest\_delete

Same as:

    $self->rest_post(
        $url,
        code => 204,
        %conf,
        method => 'DELETE',
        $data
    );

## \_capture\_args

This is a private method. It parse and validate params for rest\_post and above methods.

    my ($self, $url, $data, %conf) = &_capture_args(@_);

    So, @_ must have a items like this:

        $self, # (required) self object
        $url,  # (required) a string. If ARRAY $url will return a join '/', @$url
        %conf, # (optional) configuration hash (AKA list). Odd number will broke cause problems.
        $data  # (optional) ArrayRef, send on body as application/x-www-form-urlencoded data

    # $data can be also sent as $conf{data} = []

## rest\_post

This is the main method, and accept some options on %conf.

### Defaults options

#### is\_fail => 0,

This test if $res->is\_success must be true or false. Die with confess if not archived.

#### code => is\_fail ? 400 : 201,

This test if $res->code equivalent to expected. Die with confess if not archived.

### Optional options:

#### stash => 'foobar'

Load parsed response on `stash-`{foobar}> and some others fields

`stash-`{foobar.id}> if response code is 201 and parsed response contains ->{id}
`stash-`{foobar.url}> if response code is 201 and header contains Location (confess if missed)

#### list => 1,

This is if

## stash\_ctx

    $obj->stash_ctx(
        'easyname.get',
        sub {
            my ($me) = @_;
        }
    );


    Get an stash-name and run a CodeRef with the stash as first @_

## $t->stash

Copy from old Catalyst.pm, but $t->stash('foo') = $t->stash->{'foo'}

Returns a hashref to the stash, which may be used to store data and pass
it between components during a test. You can also set hash keys by
passing arguments. Unlike catalyst, it's never cleared, so, it lasts until object this destroy.

    $t->stash->{foo} = $bar;
    $t->stash( { moose => 'majestic', qux => 0 } );
    $t->stash( bar => 1, gorch => 2 ); # equivalent to passing a hashref

# Tests Coverage

I'm always trying to improve those numbers.
Improve branch number is a very time-consuming task. There is a room for test all checkings and defaults on tests.

    ---------------------------- ------ ------ ------ ------ ------ ------ ------
    File                           stmt   bran   cond    sub    pod   time  total
    ---------------------------- ------ ------ ------ ------ ------ ------ ------
    blib/lib/Stash/REST.pm         94.9   73.1   81.4  100.0    0.0  100.0   84.6
    Total                          94.9   73.1   81.4  100.0    0.0  100.0   84.6
    ---------------------------- ------ ------ ------ ------ ------ ------ ------

# AUTHOR

Renato CRON <rentocron@cpan.org>

# COPYRIGHT

Copyright 2015- Renato CRON

Thanks to http://eokoe.com

# LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

# SEE ALSO

[Stash::REST::TestMore](https://metacpan.org/pod/Stash::REST::TestMore), [Class::Trigger](https://metacpan.org/pod/Class::Trigger)
