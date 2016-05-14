//
// StreamManagementModule.swift
//
// TigaseSwift
// Copyright (C) 2016 "Tigase, Inc." <office@tigase.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License,
// or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. Look for COPYING file in the top folder.
// If not, see http://www.gnu.org/licenses/.
//

import Foundation

public class StreamManagementModule: Logger, XmppModule, ContextAware, XmppStanzaFilter, EventHandler {
    
    static let SM_XMLNS = "urn:xmpp:sm:3";
    
    public static let ID = SM_XMLNS;
    
    public let id = SM_XMLNS;
    
    public let criteria = Criteria.xmlns(SM_XMLNS);
    
    public let features = [String]();
    
    public var context: Context! {
        didSet {
            if oldValue != nil {
                oldValue.eventBus.unregister(self, events: SessionObject.ClearedEvent.TYPE);
            }
            if context != nil {
                context.eventBus.register(self, events: SessionObject.ClearedEvent.TYPE);
            }
        }
    }
    
    private var outgoingQueue = Queue<Stanza>();
    
    // TODO: should this stay here or be moved to sessionObject as in Jaxmpp?
    private var ackH = AckHolder();
    
    private var _ackEnabled: Bool = false;
    public var ackEnabled: Bool {
        return _ackEnabled;
    }
    
    private var lastRequestTimestamp = NSDate();
    private var lastSentH = UInt32(0);
    
    public var resumptionEnabled: Bool {
        return resumptionId != nil
    }
    
    private var resumptionId: String? = nil;
    
    private var _resumptionLocation: String? = nil;
    public var resumptionLocation: String? {
        return _resumptionLocation;
    }
    
    private var _resumptionTime: NSTimeInterval?;
    public var resumptionTime: NSTimeInterval? {
        return _resumptionTime;
    }
    
    public override init() {
        super.init();
    }
    
    public func enable(resumption: Bool = true) {
        guard !(ackEnabled || resumptionEnabled) else {
            return;
        }
        
        log("enabling StreamManagament with resume=", resumption);
        var enable = Stanza(name: "enable", xmlns: StreamManagementModule.SM_XMLNS);
        if resumption {
            enable.setAttribute("resume", value: "true");
        }
        
        context.writer?.write(enable);
    }
    
    public func handleEvent(event: Event) {
        switch event {
        case let e as SessionObject.ClearedEvent:
            for scope in e.scopes {
                switch scope {
                case .stream:
                    _ackEnabled = false;
                case .session:
                    reset();
                default:
                    break;
                }
            }
        default:
            break;
        }
    }
    
    public func isAvailable() -> Bool {
        return StreamFeaturesModule.getStringFeatures(context.sessionObject)?.findChild("sm", xmlns: StreamManagementModule.SM_XMLNS) != nil;
    }
    
    public func process(stanza: Stanza) throws {
        // all requests should be processed already
        throw ErrorCondition.undefined_condition;
    }
    
    public func processIncomingStanza(stanza: Stanza) -> Bool {
        guard ackEnabled else {
            guard stanza.xmlns == StreamManagementModule.SM_XMLNS else {
                return false;
            }
            
            switch stanza.name {
            case "resumed":
                processResumed(stanza);
            case "failed":
                processFailed(stanza);
            case "enabled":
                processEnabled(stanza);
            default:
                break;
            }
            return true;
        }
        
        guard stanza.xmlns == StreamManagementModule.SM_XMLNS else {
            ackH.incrementIncoming();
            return false;
        }
        
        switch stanza.name {
        case "a":
            processAckAnswer(stanza);
            return true;
        case "r":
            processAckRequest(stanza);
            return true;
        default:
            return false;
        }
        return false;
    }
    
    public func processOutgoingStanza(stanza: Stanza) {
        guard ackEnabled else {
            return;
        }
        
        if stanza.xmlns == StreamManagementModule.SM_XMLNS {
            switch stanza.name {
            case "a", "r":
                return;
            default:
                break;
            }
        }
        
        ackH.incrementOutgoing();
        outgoingQueue.offer(stanza);
        if (outgoingQueue.count > 3) {
            request();
        }
    }
    
    public func request() {
        if lastRequestTimestamp.timeIntervalSinceNow < 1 {
            return;
        }
        
        let r = Stanza(name: "r", xmlns: StreamManagementModule.SM_XMLNS);
        context.writer?.write(r);
        lastRequestTimestamp = NSDate();
    }
    
    public func reset() {
        _ackEnabled = false;
        resumptionId = nil
        _resumptionTime = nil;
        _resumptionLocation = nil;
        ackH.reset();
        outgoingQueue.clear();
    }
    
    public func resume() {
        log("starting stream resumption");
        var resume = Stanza(name: "resume", xmlns: StreamManagementModule.SM_XMLNS);
        resume.setAttribute("h", value: String(ackH.incomingCounter));
        resume.setAttribute("previd", value: resumptionId);
        
        context.writer?.write(resume);
    }
    
    public func sendAck() {
        guard lastSentH != ackH.incomingCounter else {
            return;
        }
        
        let value = ackH.incomingCounter;
        lastSentH = value;
        
        var a = Stanza(name: "a", xmlns: StreamManagementModule.SM_XMLNS);
        a.setAttribute("h", value: String(value));
        context.writer?.write(a);
    }
    
    func processAckAnswer(stanza: Stanza) {
        let newH = UInt32(stanza.getAttribute("h")!) ?? 0;
        _ackEnabled = true;
        let left = Int(ackH.outgoingCounter - newH);
        ackH.outgoingCounter = newH;
        while left < outgoingQueue.count {
            outgoingQueue.poll();
        }
    }
    
    func processAckRequest(stanza: Stanza) {
        let value = ackH.incomingCounter;
        lastSentH = value;

        var a = Stanza(name: "a", xmlns: StreamManagementModule.SM_XMLNS);
        a.setAttribute("h", value: String(value));
        context.writer?.write(a);
    }
    
    func processFailed(stanza: Stanza) {
        _ackEnabled = false;
        ackH.reset();
        let errorCondition = stanza.errorCondition ?? ErrorCondition.unexpected_request;
        outgoingQueue.clear();
        
        log("stream resumption failed");
        context.eventBus.fire(FailedEvent(sessionObject: context.sessionObject, errorCondition: errorCondition));
    }
    
    func processResumed(stanza: Stanza) {
        let newH = UInt32(stanza.getAttribute("h")!) ?? 0;
        _ackEnabled = true;
        let left = Int(ackH.outgoingCounter - newH);
        while left < outgoingQueue.count {
            outgoingQueue.poll();
        }
        ackH.outgoingCounter = newH;
        var oldOutgoingQueue = outgoingQueue;
        outgoingQueue = Queue<Stanza>();
        while let s = oldOutgoingQueue.poll() {
            context.writer?.write(stanza);
        }
        
        log("stream resumed");
        context.eventBus.fire(ResumedEvent(sessionObject: context.sessionObject, newH: newH, resumeId: stanza.getAttribute("previd")));
    }
    
    func processEnabled(stanza: Stanza) {
        let id = stanza.getAttribute("id");
        let r = stanza.getAttribute("resume");
        let mx = stanza.getAttribute("max");
        let resume = r == "true" || r == "1";
        _resumptionLocation = stanza.getAttribute("location");
        
        resumptionId = id;
        _ackEnabled = true;
        if mx != nil {
            _resumptionTime = Double(mx!);
        }
        
        log("stream management enabled");
        context.eventBus.fire(EnabledEvent(sessionObject: context.sessionObject, resume: resume, resumeId: id));
    }
    
    class AckHolder {
        
        var incomingCounter:UInt32 = 0;
        var outgoingCounter:UInt32 = 0;
        
        func reset() {
            incomingCounter = 0;
            outgoingCounter = 0;
        }
        
        func incrementOutgoing() {
            outgoingCounter += 1;
        }
        
        func incrementIncoming() {
            incomingCounter += 1;
        }
        
    }
    
    public class EnabledEvent: Event {
        
        public static let TYPE = EnabledEvent();
        
        public let type = "StreamManagementEnabledEvent";
        
        public let sessionObject:SessionObject!;
        public let resume: Bool;
        public let resumeId:String?;
        
        init() {
            sessionObject = nil;
            resume = false;
            resumeId = nil
        }
        
        init(sessionObject: SessionObject, resume: Bool, resumeId: String?) {
            self.sessionObject = sessionObject;
            self.resume = resume;
            self.resumeId = resumeId;
        }
        
    }

    public class FailedEvent: Event {
        
        public static let TYPE = FailedEvent();
        
        public let type = "StreamManagementFailedEvent";
        
        public let sessionObject:SessionObject!;
        public let errorCondition:ErrorCondition!;
        
        init() {
            sessionObject = nil;
            errorCondition = nil
        }
        
        init(sessionObject: SessionObject, errorCondition: ErrorCondition) {
            self.sessionObject = sessionObject;
            self.errorCondition = errorCondition;
        }
        
    }
    
    public class ResumedEvent: Event {
        
        public static let TYPE = ResumedEvent();
        
        public let type = "StreamManagementResumedEvent";
        
        public let sessionObject:SessionObject!;
        public let newH: UInt32?;
        public let resumeId:String?;
        
        init() {
            sessionObject = nil;
            newH = nil;
            resumeId = nil
        }
        
        init(sessionObject: SessionObject, newH: UInt32, resumeId: String?) {
            self.sessionObject = sessionObject;
            self.newH = newH;
            self.resumeId = resumeId;
        }
        
    }

}

class QueueNode<T> {
    
    let value: T;
    var prev: QueueNode<T>? = nil;
    var next: QueueNode<T>? = nil;
    
    init(value: T) {
        self.value = value;
    }
    
}

class Queue<T> {

    private var _count: Int = 0;
    private var head: QueueNode<T>? = nil;
    private var tail: QueueNode<T>? = nil;
    
    public var count: Int {
        return _count;
    }
    
    public init() {
    }
    
    public func clear() {
        head = nil;
        tail = nil;
        _count = 0;
    }
    
    public func offer(value: T) {
        var node = QueueNode<T>(value: value);
        if head == nil {
            self.head = node;
            self.tail = node;
        } else {
            node.next = self.head;
            self.head!.prev = node;
            self.head = node;
        }
        self._count++;
    }
    
    public func poll() -> T? {
        if tail == nil {
            return nil;
        } else {
            var temp = tail!;
            tail = temp.prev;
            if tail == nil {
                head = nil;
            }
            self._count--;
            return temp.value;
        }
    }
}
