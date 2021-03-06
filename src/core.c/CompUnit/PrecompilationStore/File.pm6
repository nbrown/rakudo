class CompUnit::PrecompilationStore::File
  does CompUnit::PrecompilationStore
{
    my class Compunit::PrecompilationStore::File::Item
      does CompUnit::PrecompilationStore::Item
    {
        has IO::Handle $!item;

        submethod BUILD (:$!item) { }

        method unlock {
            $!item.close;
            $!item.path.unlink;
        }
    }

    my class CompUnit::PrecompilationUnit::File
      does CompUnit::PrecompilationUnit
    {
        has CompUnit::PrecompilationId:D $.id   is built(:bind) is required;
        has IO::Path                     $.path is built(:bind);
        has Str $!checksum        is built;
        has Str $!source-checksum is built;
        has CompUnit::PrecompilationDependency @!dependencies is built(:bind);
        has $!bytecode            is built(:bind);
        has $!store               is built(:bind);

        has Bool $!initialized;
        has IO::Handle $!handle;
        has Lock $!update-lock;

        submethod TWEAK(--> Nil) {
            if $!bytecode {
                $!checksum = nqp::sha1($!bytecode.decode('iso-8859-1'));
                $!initialized := True;
            }
            else {
                $!initialized := False;
            }
            $!update-lock := Lock.new;
        }

        method modified(--> Instant:D) {
            $!path.modified
        }

        method !read-dependencies(--> Nil) {
            $!initialized || $!update-lock.protect: {
                return if $!initialized;  # another thread beat us
                $!handle := $!path.open(:r) unless $!handle;

                $!checksum        = $!handle.get;
                $!source-checksum = $!handle.get;
                my $dependency   := $!handle.get;
                my $dependencies := nqp::create(IterationBuffer);
                while $dependency {
                    nqp::push(
                      $dependencies,
                      CompUnit::PrecompilationDependency::File.deserialize($dependency)
                    );
                    $dependency := $!handle.get;
                }
                nqp::bindattr(@!dependencies,List,'$!reified',$dependencies);
                $!initialized := True;
            }
        }

        method dependencies(--> Array[CompUnit::PrecompilationDependency]) {
            self!read-dependencies;
            @!dependencies
        }

        method bytecode(--> Buf:D) {
            $!update-lock.protect: {
                unless $!bytecode {
                    self!read-dependencies;
                    $!bytecode := $!handle.slurp(:bin,:close)
                }
                $!bytecode
            }
        }

        method bytecode-handle(--> IO::Handle:D) {
            self!read-dependencies;
            $!handle
        }

        method source-checksum() is rw {
            self!read-dependencies;
            $!source-checksum
        }

        method checksum() is rw {
            self!read-dependencies;
            $!checksum
        }

        method Str(--> Str:D) {
            self.path.Str
        }

        method close(--> Nil) {
            $!update-lock.protect: {
                $!handle.close if $!handle;
                $!handle      := IO::Handle;
                $!initialized := False;
            }
        }

        method save-to(IO::Path $precomp-file) {
            my $handle := $precomp-file.open(:w);
            # cw: There may be an urge to just perform the file locking, here.
            #     it should be resisted. Much of the work that requires the
            #     locking starts from the moment !file() is called. So a lock
            #     here would be too late.
            $handle.print($!checksum ~ "\n");
            $handle.print($!source-checksum ~ "\n");
            $handle.print($_.serialize ~ "\n") for @!dependencies;
            $handle.print("\n");
            $handle.write($!bytecode);
            $handle.close;
            $!path := $precomp-file;
        }

        method is-up-to-date(
          CompUnit::PrecompilationDependency:D $dependency,
          Bool :$check-source
        --> Bool:D) {
            my $result := self.CompUnit::PrecompilationUnit::is-up-to-date($dependency, :$check-source);
            $!store.remove-from-cache($.id) unless $result;
            $result
        }
    }

    has IO::Path:D $.prefix is built(:bind) is required;

    has IO::Handle $!lock;
    has int $!wont-lock;
    has int $!lock-count;
    has $!loaded;
    has $!dir-cache;
    has $!compiler-cache;
    has Lock $!update-lock;

    submethod TWEAK(--> Nil) {
        $!update-lock := Lock.new;
        if $*W -> $World {
            $!wont-lock = 1 if $World.is_precompilation_mode;
        }
        $!loaded         := nqp::hash;
        $!dir-cache      := nqp::hash;
        $!compiler-cache := nqp::hash;
    }

    method new-unit(|c) {
        CompUnit::PrecompilationUnit::File.new(|c, :store(self))
    }

    method !dir(
      CompUnit::PrecompilationId:D $compiler-id,
      CompUnit::PrecompilationId:D $precomp-id
    ) {
        $!update-lock.protect: {
            my str $compiler = $compiler-id.Str;
            my str $precomp  = $precomp-id.Str;
            nqp::ifnull(
              nqp::atkey($!dir-cache,nqp::concat($compiler,$precomp)),
              nqp::bindkey($!dir-cache,nqp::concat($compiler,$precomp),
                nqp::ifnull(
                  nqp::atkey($!compiler-cache,$compiler),
                  nqp::bindkey($!compiler-cache,$compiler,
                    self.prefix.add($compiler)
                  )
                ).add(nqp::substr($precomp,0,2))
              )
            )
        }
    }

    method path(
      CompUnit::PrecompilationId:D $compiler-id,
      CompUnit::PrecompilationId:D $precomp-id,
      Str:D :$extension = ''
    ) {
        self!dir($compiler-id, $precomp-id).add($precomp-id ~ $extension)
    }

    method !lock(IO::Path $to-lock --> Nil) {
        unless $!wont-lock {
            $!update-lock.lock;
            $!lock := $to-lock.add('.lock').open(:create, :rw)
              unless $!lock;
            $!lock.lock if $!lock-count++ == 0;
        }
    }

    method unlock() {
        if $!wont-lock || $!lock-count == 0 {
            Nil
        }
        else {
            LEAVE $!update-lock.unlock;
            die "unlock when we're not locked!" if $!lock-count == 0;

            $!lock-count-- if $!lock-count > 0;
            if $!lock && $!lock-count == 0 {
                $!lock.unlock;
                $!lock.close;
                $!lock := IO::Handle;
            }
            True
        }
    }

    method load-unit(
      CompUnit::PrecompilationId:D $compiler-id,
      CompUnit::PrecompilationId:D $precomp-id
    ) {
        $!update-lock.protect: {
            my str $key = $precomp-id.Str;
            nqp::ifnull(
              nqp::atkey($!loaded,$key),
              do {
                  my $path := self.path($compiler-id, $precomp-id);
                  $path.e
                    ?? nqp::bindkey($!loaded,$key,
                         CompUnit::PrecompilationUnit::File.new(
                           :id($precomp-id), :$path, :store(self)))
                    !! Nil
              }
            )
        }
    }

    method load-repo-id(
      CompUnit::PrecompilationId:D $compiler-id,
      CompUnit::PrecompilationId:D $precomp-id
    ) {
        my $path := self.path($compiler-id, $precomp-id, :extension<.repo-id>);
        $path.e
          ?? $path.slurp
          !! Nil
    }

    method remove-from-cache(CompUnit::PrecompilationId:D $precomp-id) {
        $!update-lock.protect: {
            nqp::deletekey($!loaded,$precomp-id.Str);
            # cw: Remove file lock object?
        }
    }

    method destination(
      CompUnit::PrecompilationId:D $compiler-id,
      CompUnit::PrecompilationId:D $precomp-id,
      Str:D  :$extension = '',
      Bool:D :$lock-full = False
    --> IO::Path:D) {

        # have a writable prefix, assume it's a directory
        if $!prefix.w {
            self!lock($.prefix) if $lock-full;
            self!file($compiler-id, $precomp-id, :$extension);
        }

        # directory creation successful and writeable
        elsif $!prefix.mkdir && $!prefix.w {

            # make sure we have a tag in it
            $!prefix.child('CACHEDIR.TAG').spurt:
'Signature: 8a477f597d28d172789f06886806bc55
# This file is a cache directory tag created by Rakudo.
# For information about cache directory tags, see:
# http://www.brynosaurus.com/cachedir';

            # call ourselves again, now that we haz a cache directory
            self.destination($compiler-id, $precomp-id, :$extension)
        }

        # huh?
        else {
            Nil
        }
    }

    method !file(
      CompUnit::PrecompilationId:D $compiler-id,
      CompUnit::PrecompilationId:D $precomp-id,
      Str:D :$extension = ''
    --> IO::Path:D) {
        my $compiler-dir := self.prefix.add($compiler-id);
        $compiler-dir.mkdir unless $compiler-dir.e;

        my $dest := self!dir($compiler-id, $precomp-id);
        $dest.mkdir unless $dest.e;

        # cw: <strikethru>Create lock object, here?</strikethru>
        # cw: Create STOREUNIT object, here?
        # A mutant chicken and egg problem. The "lock" object is really something
        # that wraps an IO::Handle so that .lock can be called upon it. What is
        # created here is an IO::Path. Should we create the handle here, or
        # wait until it is created later in this process.
        #
        # Object wants to be an IO::Path, but proper ITEM-LEVEL lock handling
        # also needs control of .lock and .unlock, which is an IO::Handle
        # method.
        #
        # Frankensteining an amalgamation might be an answer but it could cause
        # developer confusion down the road.
        #
        # A new object that wraps both IO::Handle and IO::Path may be the
        # better way.

        $dest.add($precomp-id ~ $extension)
    }

    method store-file(
      CompUnit::PrecompilationId:D $compiler-id,
      CompUnit::PrecompilationId:D $precomp-id,
      IO::Path:D $path,
      Str:D :$extension = ''
    ) {
        my $file := self!file($compiler-id, $precomp-id, :$extension);
        try $path.rename($file);
    }

    method store-unit(
      CompUnit::PrecompilationId:D $compiler-id,
      CompUnit::PrecompilationId:D $precomp-id,
      CompUnit::PrecompilationUnit:D $unit
    ) {
        my $precomp-file := self!file($compiler-id, $precomp-id, :extension<.tmp>);
        $unit.save-to($precomp-file);
        try $precomp-file.rename(self!file($compiler-id, $precomp-id));
        self.remove-from-cache($precomp-id);
    }

    method store-repo-id(
      CompUnit::PrecompilationId:D $compiler-id,
      CompUnit::PrecompilationId:D $precomp-id,
      Str:D :$repo-id!
    ) {
        my $repo-id-file := self!file($compiler-id, $precomp-id, :extension<.repo-id.tmp>);
        $repo-id-file.spurt($repo-id);
        try $repo-id-file.rename(self!file($compiler-id, $precomp-id, :extension<.repo-id>));
    }

    method delete(
      CompUnit::PrecompilationId:D $compiler-id,
      CompUnit::PrecompilationId:D $precomp-id,
      Str:D :$extension = ''
    ) {
        self.path($compiler-id, $precomp-id, :$extension).unlink;
    }

    method delete-by-compiler(CompUnit::PrecompilationId:D $compiler-id) {
         my $compiler-dir := self.prefix.add($compiler-id);
         for $compiler-dir.dir -> $subdir {
             .unlink for $subdir.dir;
             $subdir.rmdir;
         }
         $compiler-dir.rmdir;
    }

    method initiate-lock (
      Str:D $location is copy
      --> Compunit::PrecompilationStore::File::Item:D
    ) {
        my $item = $location.IO.extension('lock').open(:create, :rw);
        $item.lock;

        Compunit::PrecompilationStore::File::Item.new(:$item)
    }
}

# vim: expandtab shiftwidth=4
