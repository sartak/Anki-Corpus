package Anki::Corpus;
use 5.14.0;
use warnings;
use utf8;
use Any::Moose;
use DBI;
use Params::Validate 'validate';
use Anki::Corpus::Sentence;

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

sub add_sentence {
    my $self = shift;
    my %args = validate(@_, {
        japanese    => { regex => qr/\p{Han}|\p{Hiragana}|\p{Katakana}/ },
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

    warn "Length warning (" . length($args{japanese}) . "): $args{japanese}\n"
        if length($args{japanese}) > 500;

    if (!defined($args{unsuspended}) && !$args{suspended}) {
        $args{unsuspended} = time;
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
        SELECT rowid, japanese, translation, readings, source, unsuspended
        FROM sentences
        $query
    ;");
    $sth->execute;

    my $count = 0;
    my @sentences;

    while (my @results = $sth->fetchrow_array) {
        my $sentence = Anki::Corpus::Sentence->new(
            corpus      =>  $self,
            rowid       =>  $results[0],
            japanese    =>  $results[1],
            translation =>  $results[2],
            readings    =>  $results[3],
            source      =>  $results[4],
            suspended   => !$results[5],
        );
        push @sentences, $sentence;
    }

    for (@sentences) {
        $sub->($_);
    }

    return scalar @sentences;
}

sub print_sentence {
    my $self        = shift;
    my $sentence    = shift;
    my $color_regex = shift;

    say(($sentence->id . ": " . $sentence->japanese) =~ s/$color_regex/\e[1;35m$&\e[m/gr);

    my @fields;

    for (["翻訳", 'translation'], ["読み", 'readings'], ["起こり", 'source']) {
        my ($field, $method) = @$_;
        my $value = $sentence->$method;
        push @fields, [$field, $value] if $value;
    }

    my %notes = %{ $sentence->notes };
    push @fields, map { [$_, $notes{$_} ] } sort keys %notes;

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

    my $count;

    $self->each_sentence($query, sub {
        my $sentence = shift;
        return if $filter && !$filter->($sentence);
        ++$count;
        $self->print_sentence($sentence, $color_regex);
        say "";
    });

    if ($count) {
        print "$count row";
        print "s" if $count != 1;
        print "\n";
    }

    return $count;
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

sub scan_for {
    my $self  = shift;
    my @args  = @{ shift() };
    my $cb    = shift;
    my $query = shift || 'WHERE ';

    my $order = join ", ", map { "source='$_' DESC" } (
        'MFSP',
        'Smart.fm',
        'プログレッシブ英和・和英中辞典',
        'Twitter',
        '四字熟語',
        '四字熟語 Example',
        # everything else
    );
    $order .= ', rowid ASC';

    my $regex = '(?!)';
    my @positive;
    my @negative;

    for my $clause (@ARGV) {
        if ($clause =~ s/^-//) {
            push @negative, $clause;
        }
        else {
            push @positive, $clause;
            $regex .= "|\Q$clause\E";
        }
    }

    if (@positive) {
        $query .= ' AND (' . join (' OR ', map { "japanese LIKE '%$_%'" } @positive ) . ')';
    }
    if (@negative) {
        $query .= ' AND (' . join (' AND ', map { "japanese NOT LIKE '%$_%'" } @negative ) . ')';
    }

    $query .= " ORDER BY $order";

    my $count = $self->each_sentence($query, sub {
        my $sentence = shift;
        $cb->($sentence, $regex);
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
    $dbh->do("UPDATE sentences SET unsuspended=0 WHERE rowid=?", {}, $id);
}

sub unsuspend_sentence {
    my $self = shift;
    my $id = shift;

    my $dbh = $self->dbh;
    $dbh->do("UPDATE sentences SET unsuspended=1 WHERE rowid=?", {}, $id);
}

no Any::Moose;
__PACKAGE__->meta->make_immutable;
1;

