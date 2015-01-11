# NAME

Stash::REST - Blah blah blah

# SYNOPSIS

    use Stash::REST;

# DESCRIPTION

Stash::REST is

# METHODS

## $t->stash

Copy from old Catalyst.pm, but $t->stash('foo') = $t->stash->{'foo'}

Returns a hashref to the stash, which may be used to store data and pass
it between components during a test. You can also set hash keys by
passing arguments. Unlike catalyst, it's never cleared, so, it lasts until object this destroy.

    $t->stash->{foo} = $bar;
    $t->stash( { moose => 'majestic', qux => 0 } );
    $t->stash( bar => 1, gorch => 2 ); # equivalent to passing a hashref

# AUTHOR

Renato CRON <rentocron@cpan.org>

# COPYRIGHT

Copyright 2015- Renato CRON

# LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

# SEE ALSO
