//
//  User.swift
//  Tentacle
//
//  Created by Matt Diephouse on 4/12/16.
//  Copyright © 2016 Matt Diephouse. All rights reserved.
//

import Foundation
import Argo
import Curry
import Runes

extension User {
    // https://developer.github.com/v3/users/#get-a-single-user
    internal var profile: Request {
        return Request(method: .get, path: "/users/\(login)")
    }
    
    // https://developer.github.com/v3/repos/#list-user-repositories
    internal var repositories: Request {
        return Request(method: .get, path: "/users/\(login)/repos")
    }
}

/// A user on GitHub or GitHub Enterprise.
public struct User: CustomStringConvertible {
    /// The user's login/username.
    public let login: String
    
    public init(_ login: String) {
        self.login = login
    }
    
    public var description: String {
        return login
    }
}

extension User: Hashable {
    public static func ==(lhs: User, rhs: User) -> Bool {
        return lhs.login == rhs.login
    }
    
    public var hashValue: Int {
        return login.hashValue
    }
}

/// Information about a user on GitHub.
public struct UserInfo: CustomStringConvertible {
    public enum UserType: String {
        case user = "User"
        case organization = "Organization"
    }

    /// The unique ID of the user.
    public let id: String
    
    /// The user this information is about.
    public let user: User
    
    /// The URL of the user's GitHub page.
    public let url: URL
    
    /// The URL of the user's avatar.
    public let avatarURL: URL

    /// The type of user if it's a regular one or an organization
    public let type: UserType

    public var description: String {
        return user.description
    }
}

extension UserInfo: Hashable {
    public static func ==(lhs: UserInfo, rhs: UserInfo) -> Bool {
        return lhs.id == rhs.id
            && lhs.user == rhs.user
            && lhs.url == rhs.url
            && lhs.avatarURL == rhs.avatarURL
    }

    public var hashValue: Int {
        return id.hashValue
    }
}

extension UserInfo: ResourceType {
    public static func decode(_ j: JSON) -> Decoded<UserInfo> {
        return curry(self.init)
            <^> (j <| "id" >>- toString)
            <*> (j <| "login").map(User.init)
            <*> j <| "html_url"
            <*> j <| "avatar_url"
            <*> (j <| "type" >>- toUserType)
    }
}

/// Extended information about a user on GitHub.
public struct UserProfile {
    /// The user that this information refers to.
    public let user: UserInfo
    
    /// The date that the user joined GitHub.
    public let joinedDate: Date
    
    /// The user's name if they've set one.
    public let name: String?
    
    /// The user's public email address if they've set one.
    public let email: String?
    
    /// The URL of the user's website if they've set one
    /// (the type here is a String because Github lets you use
    /// anything and doesn't validate that you've entered a valid URL)
    public let websiteURL: String?
    
    /// The user's company if they've set one.
    public let company: String?
    
    public var description: String {
        return user.description
    }
    
    public init(user: UserInfo, joinedDate: Date, name: String?, email: String?, websiteURL: String?, company: String?) {
        self.user = user
        self.joinedDate = joinedDate
        self.name = name
        self.email = email
        self.websiteURL = websiteURL
        self.company = company
    }
}

extension UserProfile: Hashable {
    public static func ==(lhs: UserProfile, rhs: UserProfile) -> Bool {
        return lhs.user == rhs.user
            && lhs.joinedDate == rhs.joinedDate
            && lhs.name == rhs.name
            && lhs.email == rhs.email
            && lhs.websiteURL == rhs.websiteURL
            && lhs.company == rhs.company
    }

    public var hashValue: Int {
        return user.hashValue
    }
}

extension UserProfile: ResourceType {
    public static func decode(_ j: JSON) -> Decoded<UserProfile> {
        return curry(self.init)
            <^> j <| []
            <*> (j <| "created_at" >>- toDate)
            <*> j <|? "name"
            <*> j <|? "email"
            <*> j <|? "blog"
            <*> j <|? "company"
    }
}
