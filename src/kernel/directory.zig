const Inode = @import("inode.zig");

const Directory = @This();

inode: *Inode,

pub fn init(inode: *Inode) Directory {
    if (inode.disk_inode.type != .directory) {
        @panic("Directory.init: inode is not a directory");
    }

    return .{ .inode = inode };
}

// Look for a directory entry in a directory.
// If found, set *poff to byte offset of entry.
pub fn lookupChild(directory: *Directory, name: []u8, entry_offset: *u32) ?*Inode {
}

//   for(off = 0; off < dp->size; off += sizeof(de)){
//     if(readi(dp, 0, (uint64)&de, off, sizeof(de)) != sizeof(de))
//       panic("dirlookup read");
//     if(de.inum == 0)
//       continue;
//     if(namecmp(name, de.name) == 0){
//       // entry matches path element
//       if(poff)
//         *poff = off;
//       inum = de.inum;
//       return iget(dp->dev, inum);
//     }
//   }
//
//   return 0;
// }
//
// // Write a new directory entry (name, inum) into the directory dp.
// // Returns 0 on success, -1 on failure (e.g. out of disk blocks).
// int
// dirlink(struct inode *dp, char *name, uint inum)
// {
//   int off;
//   struct dirent de;
//   struct inode *ip;
//
//   // Check that name is not present.
//   if((ip = dirlookup(dp, name, 0)) != 0){
//     iput(ip);
//     return -1;
//   }
//
//   // Look for an empty dirent.
//   for(off = 0; off < dp->size; off += sizeof(de)){
//     if(readi(dp, 0, (uint64)&de, off, sizeof(de)) != sizeof(de))
//       panic("dirlink read");
//     if(de.inum == 0)
//       break;
//   }
//
//   strncpy(de.name, name, DIRSIZ);
//   de.inum = inum;
//   if(writei(dp, 0, (uint64)&de, off, sizeof(de)) != sizeof(de))
//     return -1;
//
//   return 0;
// }
