package Anki::Corpus;
use 5.14.0;
use warnings;
use utf8;
use Any::Moose;
use DBI;
use Params::Validate 'validate';
use Anki::Corpus::Sentence;
use Anki::Morphology;

# ABSTRACT: interact with a corpus of sentences for Anki

has file => (
    is       => 'ro',
    isa      => 'Str',
    default  => sub { $ENV{ANKI_CORPUS} },
);

has dbh => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        my $self = shift;
        my $needs_schema = !-e $self->file;

        my $dbh = DBI->connect("dbi:SQLite:dbname=" . $self->file);
        $dbh->{sqlite_unicode} = 1;

        if ($needs_schema) {
            $self->schematize($dbh);
        }

        $dbh
    },
    handles => ['prepare'],
);

has morphology => (
    is       => 'ro',
    isa      => 'Anki::Morphology',
    lazy     => 1,
    default  => sub { Anki::Morphology->new(corpus => shift) },
);

sub add_sentence {
    my $self = shift;
    my %args = validate(@_, {
        japanese    => 1,
        translation => { default => '' },
        readings    => { default => '' },
        source      => 1,
        suspended   => { default => 1, regex => qr/\A[01]\z/ },
        created     => { default => time },
        unsuspended => { default => undef },
    });

    if ($args{japanese} =~ s/。$//) {
        warn "Truncated 。 giving $args{japanese}\n";
    }

    if ($args{japanese} =~ s/\n|<br[^>]*>/  /g) {
        warn "Replaced newlines with two spaces giving $args{japanese}\n";
    }

    if ($args{japanese} !~ /\p{Han}|\p{Hiragana}|\p{Katakana}/) {
        warn "Skipping this sentence which apparently lacks Japanese: $args{japanese}\n";
        return;
    }

    warn "Length warning (" . length($args{japanese}) . "): $args{japanese}\n"
        if length($args{japanese}) > 500;

    if (!defined($args{unsuspended}) && !$args{suspended}) {
        $args{unsuspended} = time;
    }

    for my $key ('translation', 'readings') {
        if ($args{$key} =~ s/<br[^>]*>/\n/g) {
            warn "Replaced <br>s in $key with newlines, giving $args{$key}\n";
        }
    }


    my $old_warn = $SIG{__WARN__} = sub { warn shift };
    local $SIG{__WARN__} = sub {
        my $warning = shift;
        $old_warn->($warning, @_) unless $warning =~ /column japanese is not unique/;
    };

    my $dbh = $self->dbh;
    my $ok = $dbh->do("INSERT INTO sentences (japanese, translation, readings, source, suspended, created, unsuspended) values (?, ?, ?, ?, ?, ?, ?);", {},
        $args{japanese},
        $args{translation},
        $args{readings},
        $args{source},
        $args{suspended},
        $args{created},
        $args{unsuspended},
    );
    return unless $ok && defined wantarray;
    return ($dbh->selectrow_array("select max(rowid) from sentences;"))[0];
}

sub schematize {
    my $self = shift;
    my $dbh = shift;

    $dbh->do(<< '    SCHEMA');
        CREATE TABLE sentences (
            rowid INTEGER PRIMARY KEY AUTOINCREMENT,
            japanese TEXT UNIQUE NOT NULL,
            translation TEXT,
            readings TEXT,
            source TEXT NOT NULL,
            morphemes TEXT,
            suspended BOOLEAN,
            created INTEGER NOT NULL,
            unsuspended INTEGER
        );
        CREATE TABLE notes (
            sentence INTEGER NOT NULL,
            type TEXT NOT NULL,
            value TEXT NOT NULL
        );
    SCHEMA
}

sub each_sentence {
    my $self  = shift;
    my $query = shift;
    my $sub   = shift;

    my $sth = $self->prepare("
        SELECT rowid, japanese, translation, readings, source, suspended
        FROM sentences
        $query
    ;");
    $sth->execute;

    my $count = 0;
    my @sentences;

    while (my @results = $sth->fetchrow_array) {
        my $sentence = Anki::Corpus::Sentence->new(
            corpus      => $self,
            rowid       => $results[0],
            japanese    => $results[1],
            translation => $results[2],
            readings    => $results[3],
            source      => $results[4],
            suspended   => $results[5],
        );
        push @sentences, $sentence;
    }

    my $i = 0;
    while ($i >= 0 && $i < @sentences) {
        my $sentence = $sentences[$i];
        my $next = $i + 1;

        $sub->($sentence, $i, scalar(@sentences), \$next);

        $i = $next;
    }

    return scalar @sentences;
}

sub print_sentence {
    my $self        = shift;
    my $sentence    = shift;
    my $color_regex = shift;

    my @fields;

    for (["翻訳", 'translation'], ["読み", 'readings'], ["起こり", 'source']) {
        my ($field, $method) = @$_;
        my $value = $sentence->$method;

        if (!$value && $method eq 'readings' && !$ENV{DONT_INTUIT_READINGS}) {
            $field = $method = 'intuited_readings';
            $value = $sentence->$method;
        }

        push @fields, [$field, $value] if $value;
    }

    my %notes = %{ $sentence->notes };
    push @fields, map { [$_, $notes{$_} ] } sort keys %notes;

    my $japanese = $sentence->japanese;
    say(($sentence->id . ": $japanese") =~ s/$color_regex/\e[1;35m$&\e[m/gr);
    for (@fields) {
        my ($field, $value) = @$_;
        $value =~ s/\n/\n        /g;
        say "    $field: $value" =~ s/$color_regex/\e[1;35m$&\e[m/gr;
    }
}

sub print_each {
    my $self        = shift;
    my $query       = shift;
    my $filter      = shift;
    my $color_regex = shift || qr/(?!)/;

    my $real_count;

    $self->each_sentence($query, sub {
        my ($sentence, $index, $count, $next) = @_;
        return if $filter && !$filter->($sentence);
        ++$real_count;
        $self->print_sentence($sentence, $color_regex);
        say "";
    });

    if ($real_count) {
        print "$real_count row";
        print "s" if $real_count != 1;
        print "\n";
    }

    return $real_count;
}

sub add_note {
    my $self = shift;
    my %args = validate(@_, {
        sentence => 1,
        type     => 1,
        value    => 1,
    });

    my $dbh = $self->dbh;
    $dbh->do("INSERT INTO notes (sentence, type, value) values (?, ?, ?);", {},
        $args{sentence},
        $args{type},
        $args{value},
    );
}

sub notes_for {
    my $self = shift;
    my $id = shift;

    my $sth = $self->prepare("
        select type, value
        from notes
        where sentence = ?
    ;");

    $sth->execute($id);
    my %notes;
    while (my ($type, $value) = $sth->fetchrow_array) {
        $notes{$type} = $value;
    }

    return %notes;
}

sub order {
    my $self = shift;

    my $order = join ", ", map { "source='$_' DESC" } (
        'MFSP',
        'Smart.fm',
        'ARES-3',
        '歌詞',
        'プログレッシブ英和・和英中辞典',
        '四字熟語',
        '四字熟語 Example',
        'Twitter',
        # everything else
    );
    $order .= ', rowid ASC';
    return $order;
}

sub scan_for {
    my $self  = shift;
    my @args  = @{ shift() };
    my $cb    = shift;
    my $query = shift || 'WHERE 1';

    my $order = $self->order;

    my $color_regex = '(?!)';
    my @positive;
    my @negative;

    for my $clause (@ARGV) {
        if ($clause =~ s/^-//) {
            push @negative, $clause;
        }
        else {
            push @positive, $clause;
            my ($field, $value) = $clause =~ /^(\w+):(.+)/;
            $value ||= $clause;
            $color_regex .= "|\Q$value\E";
        }
    }

    if (@positive) {
        $query .= ' AND (' . join (' OR ', map { /^(\w+):(.+)/ ? "$1 LIKE '%$2%'" : "japanese LIKE '%$_%'" } @positive ) . ')';
    }
    if (@negative) {
        $query .= ' AND (' . join (' AND ', map { /^(\w+):(.+)/ ? "$1 NOT LIKE '%$2%'" : "japanese NOT LIKE '%$_%'" } @negative ) . ')';
    }

    $query .= " ORDER BY $order";

    my $count = $self->each_sentence($query, sub {
        my ($sentence, $index, $count, $next) = @_;
        $cb->(
            sentence => $sentence,
            index    => $index,
            count    => $count,
            next     => $next,
            regex    => $color_regex,
        );
    });

    if ($count) {
        print "$count row";
        print "s" if $count != 1;
        say "";
    }

    return $count;
}

sub suspend_sentence {
    my $self = shift;
    my $id = shift;

    my $dbh = $self->dbh;
    $dbh->do("UPDATE sentences SET suspended=1, unsuspended=? WHERE rowid=?", {}, time, $id);
}

sub unsuspend_sentence {
    my $self = shift;
    my $id = shift;

    my $dbh = $self->dbh;
    $dbh->do("UPDATE sentences SET suspended=0, unsuspended=NULL WHERE rowid=?", {}, $id);
}

sub count_notes_of_type {
    my $self = shift;
    my $type = shift;

    my $sth = $self->prepare("SELECT count(*) FROM notes WHERE type=?");
    $sth->execute($type);
    return @{ $sth->fetchrow_arrayref }[0];
}

no Any::Moose;
__PACKAGE__->meta->make_immutable;
1;

