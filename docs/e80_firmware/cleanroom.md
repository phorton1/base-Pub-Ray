# Cleanroom

folders: **[Home](readme.md)** --
**[Architecture](architecture/readme.md)** --
**[Abstracts](abstracts/readme.md)** --
**[Deployment](deployment/readme.md)** --
**Cleanroom**

The cleanroom holds the project's **safely-transferable reference
implementations and specifications**: working navMate-side code
(`cleanroom/e80Config.pm`, `cleanroom/e80ScreenGrab.pm`, with their API docs)
and protocol specs, grown here and projected out to navMate.

A reference implementation may carry the literal device constants it needs to
run -- command words, target addresses, vtable and phase values -- because
those constants *are* the wire protocol it implements. What stays out of
cleanroom material is anything that is not the implementation or its facts.

These articles are projected to navMate by the project's push, not by hand.
