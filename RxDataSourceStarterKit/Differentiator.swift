//
//  Differentiator.swift
//  RxExample
//
//  Created by Krunoslav Zaher on 6/27/15.
//  Copyright (c) 2015 Krunoslav Zaher. All rights reserved.
//

import Foundation

enum EditEvent : Printable {
    case Inserted           // can't be found in old sections
    case Deleted            // Was in old, not in new, in it's place is something "not new" :(, otherwise it's Updated
    case Moved              // same item, but was on different index, and needs explicit move
    case MovedAutomatically // don't need to specify any changes for those rows
    case Untouched
    
    var description: String {
        get {
            switch self {
            case .Inserted:
                return "Inserted"
            case .Deleted:
                return "Deleted"
            case .Moved:
                return "Moved"
            case .MovedAutomatically:
                return "MovedAutomatically"
            case .Untouched:
                return "Untouched"
            }
        }
    }
}

struct SectionAdditionalInfo : Printable {
    var event: EditEvent
    var indexAfterDelete: Int?
    
    var description: String {
        get {
            return "\(event), \(indexAfterDelete)"
        }
    }
}

struct ItemAdditionalInfo : Printable {
    var event: EditEvent
    var indexAfterDelete: Int?
    
    var description: String {
        get {
            return "\(event) \(indexAfterDelete)"
        }
    }
}

func indexSections<S: SectionModelType where S: Hashable, S.Item: Hashable>(sections: [S]) -> [S : Int] {
    var indexedSections: [S : Int] = [:]
    for (i, section) in enumerate(sections) {
        precondition(indexedSections[section] == nil, "Section \(section) has already been indexed at \(indexedSections[section]!)")
        indexedSections[section] = i
    }
    
    return indexedSections
}

func indexSectionItems<S: SectionModelType where S: Hashable, S.Item: Hashable>(sections: [S]) -> [S.Item : (Int, Int)] {
    var totalItems = 0
    for i in 0 ..< sections.count {
        totalItems += sections[i].items.count
    }
    
    // let's make sure it's enough
    var indexedItems: [S.Item : (Int, Int)] = Dictionary(minimumCapacity: totalItems * 3)
    
    for i in 0 ..< sections.count {
        for (j, item) in enumerate(sections[i].items) {
            precondition(indexedItems[item] == nil, "Item \(item) has already been indexed at \(indexedItems[item]!)" )
            indexedItems[item] = (i, j)
        }
    }
    
    return indexedItems
}


/*

I've uncovered this case during random stress testing of logic.
This is the hardest generic update case that causes two passes, first delete, and then move/insert

[
NumberSection(model: "1", items: [1111]),
NumberSection(model: "2", items: [2222]),
]

[
NumberSection(model: "2", items: [0]),
NumberSection(model: "1", items: []),
]

If update is in the form

* Move section from 2 to 1
* Delete Items at paths 0 - 0, 1 - 0
* Insert Items at paths 0 - 0

or

* Move section from 2 to 1
* Delete Items at paths 0 - 0
* Reload Items at paths 1 - 0

or

* Move section from 2 to 1
* Delete Items at paths 0 - 0
* Reload Items at paths 0 - 0

it crashes table view.

No matter what change is performed, it fails for me.
If anyone knows how to make this work for one Changeset, PR is welcome.

*/

// If you are considering working out your own algorithm, these are tricky
// transition cases that you can use.

// case 1
/*
from = [
    NumberSection(model: "section 4", items: [10, 11, 12]),
    NumberSection(model: "section 9", items: [25, 26, 27]),
]
to = [
    HashableSectionModel(model: "section 9", items: [11, 26, 27]),
    HashableSectionModel(model: "section 4", items: [10, 12])
]
*/

// case 2
/*
from = [
    HashableSectionModel(model: "section 10", items: [26]),
    HashableSectionModel(model: "section 7", items: [5, 29]),
    HashableSectionModel(model: "section 1", items: [14]),
    HashableSectionModel(model: "section 5", items: [16]),
    HashableSectionModel(model: "section 4", items: []),
    HashableSectionModel(model: "section 8", items: [3, 15, 19, 23]),
    HashableSectionModel(model: "section 3", items: [20])
]
to = [
    HashableSectionModel(model: "section 10", items: [26]),
    HashableSectionModel(model: "section 1", items: [14]),
    HashableSectionModel(model: "section 9", items: [3]),
    HashableSectionModel(model: "section 5", items: [16, 8]),
    HashableSectionModel(model: "section 8", items: [15, 19, 23]),
    HashableSectionModel(model: "section 3", items: [20]),
    HashableSectionModel(model: "Section 2", items: [7])
]
*/

// case 3
/*
from = [
    HashableSectionModel(model: "section 4", items: [5]),
    HashableSectionModel(model: "section 6", items: [20, 14]),
    HashableSectionModel(model: "section 9", items: []),
    HashableSectionModel(model: "section 2", items: [2, 26]),
    HashableSectionModel(model: "section 8", items: [23]),
    HashableSectionModel(model: "section 10", items: [8, 18, 13]),
    HashableSectionModel(model: "section 1", items: [28, 25, 6, 11, 10, 29, 24, 7, 19])
]
to = [
    HashableSectionModel(model: "section 4", items: [5]),
    HashableSectionModel(model: "section 6", items: [20, 14]),
    HashableSectionModel(model: "section 9", items: [16]),
    HashableSectionModel(model: "section 7", items: [17, 15, 4]),
    HashableSectionModel(model: "section 2", items: [2, 26, 23]),
    HashableSectionModel(model: "section 8", items: []),
    HashableSectionModel(model: "section 10", items: [8, 18, 13]),
    HashableSectionModel(model: "section 1", items: [28, 25, 6, 11, 10, 29, 24, 7, 19])
]
*/


// Generates differential changes suitable for sectioned view consumption.
// It will not only detect changes between two states, but it will also try to compress those changes into
// almost minimal set of changes.
//
// I know, I know, it's ugly :( Totally agree, but this is the only general way I could find that works 100%, and
// avoids UITableView quirks.
//
// Please take into consideration that I was also convinced about 20 times that I've found a simple general
// solution, but then UITableView falls apart under stress testing :(
//
// Sincerely, if somebody else would present me this 250 lines of code, I would call him a mad man. I would think
// that there has to be a simpler solution. Well, after 3 days, I'm not convinced any more :)
//
// Maybe it can be made somewhat simpler, but don't think it can be made much simpler.
//
// The algorithm could take anywhere from 1 to 3 table view transactions to finish the updates.
//
//  * stage 1 - remove deleted sections and items
//  * stage 2 - move sections into place
//  * stage 3 - fix moved and new items
//
// There maybe exists a better division, but time will tell.
//
func differentiate<S: SectionModelType where S: Hashable, S.Item: Hashable>(
        initialSections: [S],
        finalSections: [S]
    )
    -> [Changeset<S>] {
        
    typealias I = S.Item

    var deletes = Changeset<S>()
    var newAndMovedSections = Changeset<S>()
    var newAndMovedItems = Changeset<S>()
        
    let minSectionsLength = min(initialSections.count, finalSections.count)
 
    var initialSectionInfos = [SectionAdditionalInfo](count: initialSections.count, repeatedValue: SectionAdditionalInfo(event: .Untouched,  indexAfterDelete: nil))
    var finalSectionInfos = [SectionAdditionalInfo](count: finalSections.count, repeatedValue: SectionAdditionalInfo(event: .Untouched, indexAfterDelete: nil))
    
    var initialSectionIndexes: [S : Int] = [:]
    var finalSectionIndexes: [S : Int] = [:]
    
    let defaultItemInfo = ItemAdditionalInfo(event: .Untouched, indexAfterDelete: nil)
    var initialItemInfos = initialSections.map { s in
        return [ItemAdditionalInfo](count: s.items.count, repeatedValue: defaultItemInfo)
    }
    
    var finalItemInfos = finalSections.map { s in
        return [ItemAdditionalInfo](count: s.items.count, repeatedValue: defaultItemInfo)
    }
    
    initialSectionIndexes = indexSections(initialSections)
    finalSectionIndexes = indexSections(finalSections)
    
    var initialItemIndexes: [I: (Int, Int)] = indexSectionItems(initialSections)
    var finalItemIndexes: [I: (Int, Int)] = indexSectionItems(finalSections)

    // mark deleted sections {
    // 1rst stage
    var sectionIndexAfterDelete = 0
    for (i, initialSection) in enumerate(initialSections) {
        if finalSectionIndexes[initialSection] == nil {
            initialSectionInfos[i].event = .Deleted
            deletes.deletedSections.append(i)
        }
        else {
            initialSectionInfos[i].indexAfterDelete = sectionIndexAfterDelete
            sectionIndexAfterDelete++
        }
    }
    
    deletes.deletedSections = deletes.deletedSections.reverse()
        
    // }

    var untouchedOldIndex: Int? = 0
    let findNextUntouchedOldIndex = { (initialSearchIndex: Int?) -> Int? in
        var i = initialSearchIndex
        
        while i != nil && i < initialSections.count {
            if initialSectionInfos[i!].event == .Untouched {
                return i
            }
            
            i = i! + 1
        }
        
        return nil
    }
    
    // inserted and moved sections {
    // this should fix all sections and move them into correct places
    // 2nd stage
    for (i, finalSection) in enumerate(finalSections) {
        untouchedOldIndex = findNextUntouchedOldIndex(untouchedOldIndex)
        
        // oh, it did exist
        if let oldSectionIndex = initialSectionIndexes[finalSection] {
            let moveType = oldSectionIndex != untouchedOldIndex ? EditEvent.Moved : EditEvent.MovedAutomatically
            
            finalSectionInfos[i].event = moveType
            initialSectionInfos[oldSectionIndex].event = moveType
            
            if moveType == .Moved {
                let moveCommand = (from: initialSectionInfos[oldSectionIndex].indexAfterDelete!, to: i)
                newAndMovedSections.movedSections.append(moveCommand)
            }
        }
        else {
            finalSectionInfos[i].event = .Inserted
            newAndMovedSections.insertedSections.append(i)
        }
    }
    // }
    
    // mark deleted items {
    // 1rst stage again (I know, I know ...)
    for (i, initialSection) in enumerate(initialSections) {
        let event = initialSectionInfos[i].event
        
        // Deleted section will take care of deleting child items.
        // In case of moving an item from deleted section, tableview will
        // crash anyway, so this is not limiting anything.
        if event == .Deleted {
            continue
        }
        
        var indexAfterDelete = 0
        for (j, initialItem) in enumerate(initialSection.items) {
            if let finalItemIndex = finalItemIndexes[initialItem] {
                let targetSectionEvent = finalSectionInfos[finalItemIndex.0].event
                // In case there is move of item from existing section into new section
                // that is also considered a "delete"
                if targetSectionEvent == .Inserted {
                    initialItemInfos[i][j].event = .Deleted
                    deletes.deletedItems.append(ItemPath(sectionIndex: i, itemIndex: j))
                    continue
                }
            
                initialItemInfos[i][j].indexAfterDelete = indexAfterDelete
                indexAfterDelete++
            }
            else {
                initialItemInfos[i][j].event = .Deleted
                deletes.deletedItems.append(ItemPath(sectionIndex: i, itemIndex: j))
            }
        }
    }
    // }
        
    deletes.deletedItems = deletes.deletedItems.reverse()
    
    // mark new and moved items {
    // 3rd stage
    for (i, finalSection) in enumerate(finalSections) {
        let finalSection = finalSections[i]
        
        var originalSection: Int? = initialSectionIndexes[finalSection]
        
        var untouchedOldIndex: Int? = 0
        let findNextUntouchedOldIndex = { (initialSearchIndex: Int?) -> Int? in
            var i2 = initialSearchIndex
            
            while originalSection != nil && i2 != nil && i2! < initialItemInfos[originalSection!].count {
                if initialItemInfos[originalSection!][i2!].event == .Untouched {
                    return i2
                }
                
                i2 = i2! + 1
            }
            
            return nil
        }
        
        let sectionEvent = finalSectionInfos[i].event
        // new and deleted sections cause reload automatically
        if sectionEvent != .Moved && sectionEvent != .MovedAutomatically {
            continue
        }
        
        for (j, finalItem) in enumerate(finalSection.items) {
            let currentItemEvent = finalItemInfos[i][j].event
            
            precondition(currentItemEvent == .Untouched)
            
            untouchedOldIndex = findNextUntouchedOldIndex(untouchedOldIndex)
            
            // ok, so it was moved from somewhere
            if let originalIndex = initialItemIndexes[finalItem] {
                
                // In case trying to move from deleted section, abort, otherwise it will crash table view
                if initialSectionInfos[originalIndex.0].event == .Deleted {
                    finalItemInfos[i][j].event = .Inserted
                    newAndMovedItems.insertedItems.append(ItemPath(sectionIndex: i, itemIndex: j))
                }
                // original section can't be inserted
                else if initialSectionInfos[originalIndex.0].event == .Inserted {
                    fatalError("New section in initial sections, that is wrong")
                }
                // what's left is moved section
                else {
                    precondition(initialSectionInfos[originalIndex.0].event == .Moved || initialSectionInfos[originalIndex.0].event == .MovedAutomatically)
                    
                    let currentItemSectionIndexAfterDelete = initialSectionInfos[originalIndex.0].indexAfterDelete!
                    let currentItemIndexAfterDelete = initialItemInfos[originalIndex.0][originalIndex.1].indexAfterDelete!
                    
                    let eventType =
                           originalIndex.0 == (originalSection ?? -1)
                        && originalIndex.1 == (untouchedOldIndex ?? -1)
                        
                        ? EditEvent.MovedAutomatically : EditEvent.Moved
                    
                    // println("\(finalItem) \(eventType) \(originalIndex), \(originalSection) \(untouchedOldIndex)")
                    
                    initialItemInfos[originalIndex.0][originalIndex.1].event = eventType
                    finalItemInfos[i][j].event = eventType

                    if eventType == .Moved {
                        let finalSectionIndex = finalSectionIndexes[initialSections[originalIndex.0]]!
                        let moveFromItemWithIndex = initialItemInfos[originalIndex.0][originalIndex.1].indexAfterDelete!
                        
                        let moveCommand = (
                            from: ItemPath(sectionIndex: finalSectionIndex, itemIndex: moveFromItemWithIndex),
                            to: ItemPath(sectionIndex: i, itemIndex: j)
                        )
                        newAndMovedItems.movedItems.append(moveCommand)
                    }
                }
            }
            // if it wasn't moved from anywhere, it's inserted
            else {
                finalItemInfos[i][j].event = .Inserted
                newAndMovedItems.insertedItems.append(ItemPath(sectionIndex: i, itemIndex: j))
            }
        }
    }
    // }
    
    var result: [Changeset<S>] = []
    
    if deletes.deletedItems.count > 0 || deletes.deletedSections.count > 0 {
        deletes.finalSections = []
        for (i, s) in enumerate(initialSections) {
            if initialSectionInfos[i].event == .Deleted {
                continue
            }
            
            var items: [I] = []
            for (j, item) in enumerate(s.items) {
                if initialItemInfos[i][j].event != .Deleted {
                    items.append(item)
                }
            }
            deletes.finalSections.append(S(original: s, items: items))
        }
        result.append(deletes)
    }
    
    if newAndMovedSections.insertedSections.count > 0 || newAndMovedSections.movedSections.count > 0 || newAndMovedSections.updatedSections.count != 0 {
        // sections should be in place, but items should be original without deleted ones
        newAndMovedSections.finalSections = []
        for (i, s) in enumerate(finalSections) {
            let event = finalSectionInfos[i].event
            
            if event == .Inserted {
                // it's already set up
                newAndMovedSections.finalSections.append(s)
            }
            else if event == .Moved || event == .MovedAutomatically {
                let originalSectionIndex = initialSectionIndexes[s]!
                let originalSection = initialSections[originalSectionIndex]
                
                var items: [I] = []
                for (j, item) in enumerate(originalSection.items) {
                    if initialItemInfos[originalSectionIndex][j].event != .Deleted {
                        items.append(item)
                    }
                }
                
                newAndMovedSections.finalSections.append(S(original: s, items: items))
            }
            else {
                fatalError("This is weird, this shouldn't happen")
            }
        }
        
        result.append(newAndMovedSections)
    }
    
    newAndMovedItems.finalSections = finalSections
    result.append(newAndMovedItems)
    
    return result
}

