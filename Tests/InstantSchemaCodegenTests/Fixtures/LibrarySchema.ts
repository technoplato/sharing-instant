/**
 * Library Management System Schema
 * 
 * A comprehensive example demonstrating:
 * - Multi-line JSDoc comments
 * - All field types
 * - Optional fields
 * - One-to-one, one-to-many, and many-to-many relationships
 * - Complex documentation with examples
 * 
 * @author InstantDB Team
 * @version 1.0.0
 */

import { i } from "@instantdb/core";

const _schema = i.schema({
  entities: {
    /**
     * A library member who can borrow books.
     * 
     * Members have a unique email address and can:
     * - Borrow multiple books at once
     * - Have a favorite author
     * - Express interest in multiple genres
     * 
     * @example
     * ```typescript
     * const member = {
     *   id: "mem_123",
     *   name: "Jane Doe",
     *   email: "jane@example.com"
     * };
     * ```
     */
    members: i.entity({
      /** The member's full name (first and last) */
      name: i.string(),
      
      /**
       * The member's email address.
       * Must be unique across all members.
       */
      email: i.string(),
      
      /** When the member joined the library */
      memberSince: i.date(),
      
      /** Whether the membership is currently active */
      isActive: i.boolean(),
      
      /** Optional phone number for SMS notifications */
      phoneNumber: i.string().optional(),
      
      /** Number of books currently borrowed (0-10) */
      currentBorrowCount: i.number(),
      
      /** Member preferences stored as JSON */
      preferences: i.json().optional(),
    }),
    
    /**
     * An author who writes books.
     * 
     * Authors can write multiple books and have fans.
     */
    authors: i.entity({
      /** Author's full name as it appears on book covers */
      name: i.string(),
      
      /** Author's biography */
      bio: i.string().optional(),
      
      /** Birth year (e.g., 1965) */
      birthYear: i.number().optional(),
      
      /** Whether the author is still alive and writing */
      isActive: i.boolean(),
      
      /** Total number of published books */
      bookCount: i.number(),
    }),
    
    /**
     * A book in the library catalog.
     * 
     * ## ISBN Format
     * 
     * We support both ISBN-10 and ISBN-13 formats.
     * Store without hyphens for consistency.
     */
    books: i.entity({
      /** Book title as it appears on the cover */
      title: i.string(),
      
      /** International Standard Book Number */
      isbn: i.string(),
      
      /** Year of first publication */
      publicationYear: i.number(),
      
      /** Number of pages in the book */
      pageCount: i.number().optional(),
      
      /** Brief description or back-cover blurb */
      description: i.string().optional(),
      
      /** Average rating from 1.0 to 5.0 */
      averageRating: i.number().optional(),
      
      /** Number of copies available for borrowing */
      availableCopies: i.number(),
      
      /** Extended metadata as JSON */
      metadata: i.json().optional(),
    }),
    
    /**
     * A book genre/category.
     */
    genres: i.entity({
      /** Genre name (e.g., "Science Fiction") */
      name: i.string(),
      
      /** Short code for the genre (e.g., "SF") */
      code: i.string(),
      
      /** Description of what books fit this genre */
      description: i.string().optional(),
      
      /** Number of books in this genre */
      bookCount: i.number(),
    }),
    
    /**
     * A record of a book being borrowed.
     */
    borrowRecords: i.entity({
      /** When the book was borrowed */
      borrowedAt: i.date(),
      
      /** When the book is/was due */
      dueAt: i.date(),
      
      /** When the book was returned (null if still borrowed) */
      returnedAt: i.date().optional(),
      
      /** Late fee in cents (0 if returned on time) */
      lateFeeInCents: i.number().optional(),
    }),
  },
  
  links: {
    /**
     * Author → Books relationship.
     * 
     * An author writes many books.
     * A book is written by exactly one author.
     */
    authorBooks: {
      forward: { on: "authors", has: "many", label: "books" },
      reverse: { on: "books", has: "one", label: "author" },
    },
    
    /**
     * Book ↔ Genre relationship (many-to-many).
     * 
     * A book can belong to multiple genres.
     * A genre contains many books.
     */
    bookGenres: {
      forward: { on: "books", has: "many", label: "genres" },
      reverse: { on: "genres", has: "many", label: "books" },
    },
    
    /**
     * Book → Current Borrower relationship.
     * 
     * A book can be borrowed by at most one member at a time.
     * A member can borrow multiple books.
     */
    bookBorrower: {
      forward: { on: "books", has: "one", label: "currentBorrower" },
      reverse: { on: "members", has: "many", label: "borrowedBooks" },
    },
    
    /**
     * Member → Favorite Author relationship.
     */
    memberFavoriteAuthor: {
      forward: { on: "members", has: "one", label: "favoriteAuthor" },
      reverse: { on: "authors", has: "many", label: "fans" },
    },
    
    /**
     * Member ↔ Genre Interests (many-to-many).
     */
    memberGenreInterests: {
      forward: { on: "members", has: "many", label: "genreInterests" },
      reverse: { on: "genres", has: "many", label: "interestedMembers" },
    },
    
    /**
     * Borrow Record → Book relationship.
     */
    borrowRecordBook: {
      forward: { on: "borrowRecords", has: "one", label: "book" },
      reverse: { on: "books", has: "many", label: "borrowHistory" },
    },
    
    /**
     * Borrow Record → Member relationship.
     */
    borrowRecordMember: {
      forward: { on: "borrowRecords", has: "one", label: "member" },
      reverse: { on: "members", has: "many", label: "borrowHistory" },
    },
  },
});

export type Schema = typeof _schema;








