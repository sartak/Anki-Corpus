package Anki::Corpus;
use Any::Moose;
use DBI;
use Params::Validate 'validate';

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
        notes       => { default => undef },
    });

    warn "Length warning (" . length($args{japanese}) . "): $args{japanese}\n"
        if $args{japanese} > 500;

    if (!defined($args{unsuspended}) && !$args{suspended}) {
        $args{unsuspended} = time;
    }

    my $dbh = $self->dbh;
    $dbh->do("INSERT INTO sentences (japanese, translation, readings, source, suspended, created, unsuspended, notes) values (?, ?, ?, ?, ?, ?, ?, ?);", {},
        $args{japanese},
        $args{translation},
        $args{readings},
        $args{source},
        $args{suspended},
        $args{created},
        $args{unsuspended},
        $args{notes},
    );
}

sub schematize {
    my $self = shift;
    my $dbh = shift;

    $dbh->do(<< '    SCHEMA');
        CREATE TABLE sentences (
            japanese TEXT UNIQUE NOT NULL,
            translation TEXT,
            readings TEXT,
            source TEXT NOT NULL,
            suspended BOOLEAN,
            created INTEGER NOT NULL,
            unsuspended INTEGER,
            notes TEXT
        );
    SCHEMA
}

1;

