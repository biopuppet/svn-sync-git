# SVN Sync Git
Sync changes between SVN repo and Git repo.

## Implementation
To keep SVN and Git history separated without affecting each other(`dcommit` will rehash commit), using a `inter/` branch to cherry-pick each commit to the other side.
