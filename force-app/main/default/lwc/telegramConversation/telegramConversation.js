import { LightningElement, api, track, wire } from 'lwc';
import getOrCreateConversation from '@salesforce/apex/TelegramMessagingService.getOrCreateConversation';
import sendMessage from '@salesforce/apex/TelegramMessagingService.sendMessage';
import startNewSession from '@salesforce/apex/TelegramMessagingService.startNewSession';
import endSession from '@salesforce/apex/TelegramMessagingService.endSession';
//import createConversation from '@salesforce/apex/TelegramMessagingService.createConversation';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class TelegramConversation extends LightningElement {
    @api recordId;
    @track conversationData = {};
    @track messageText = '';
    @track isSending = false;
    @track isLoading = true;
    @track showEmojiPicker = false;
    @track selectedFile = null;
    @track fileName = '';
    @track filePreviewUrl = '';
    @track attachmentUrl = '';

    // Emoji data
    emojis = ['😀', '😃', '😄', '😁', '😆', '😅', '😂', '🤣', '😊', '😇', 
              '🙂', '🙃', '😉', '😌', '😍', '🥰', '😘', '😗', '😙', '😚',
              '😋', '😛', '😝', '😜', '🤪', '🤨', '🧐', '🤓', '😎', '🤩',
              '🥳', '😏', '😒', '😞', '😔', '😟', '😕', '🙁', '☹️', '😣'];

    wiredConversation;
    refreshInterval;

    connectedCallback() {
        console.log('🔗 TelegramConversation connected for record:', this.recordId);
        // Don't load immediately - wait for recordId to be properly set
        if (this.hasValidRecordId) {
            this.loadConversation();
        }
        this.refreshInterval = setInterval(() => {
            this.refreshConversation();
        }, 10000);
    }

    disconnectedCallback() {
        if (this.refreshInterval) {
            clearInterval(this.refreshInterval);
        }
    }

    @wire(getOrCreateConversation, { recordId: '$recordId' })
    wiredConversation(result) {
        this.wiredConversation = result;
        console.log('🔍 Wire method result:', result);
        console.log('🔍 Record ID:', this.recordId);
        
        // Don't process if recordId is undefined or invalid
        if (!this.hasValidRecordId) {
            console.log('⏳ Waiting for valid recordId...');
            this.isLoading = false;
            return;
        }
        
        console.log('🔍 Has data:', !!result.data);
        console.log('🔍 Has error:', !!result.error);
        
        if (result.data) {
            this.conversationData = result.data;
            this.isLoading = false;
            console.log('✅ Conversation data loaded:', this.conversationData);
            console.log('✅ Thread ID:', this.conversationData.thread?.id);
            console.log('✅ Has Active Session:', this.conversationData.hasActiveSession);
            console.log('✅ Messages count:', this.conversationData.messages?.length);
            console.log('✅ Error message:', this.conversationData.error);
            
            setTimeout(() => {
                this.scrollToBottom();
            }, 100);
            
        } else if (result.error) {
            console.error('❌ Error loading conversation:', result.error);
            console.error('❌ Error details:', JSON.stringify(result.error));
            this.isLoading = false;
            this.showToast('Error', this.extractErrorMessage(result.error), 'error');
        } else {
            console.log('⏳ Wire method still loading...');
        }
    }

    // Load conversation data
    loadConversation() {
        if (!this.hasValidRecordId) {
            console.log('⏳ Skipping load - no valid recordId');
            return;
        }
        
        console.log('🔄 Loading conversation...');
        this.isLoading = true;
        refreshApex(this.wiredConversation).catch(error => {
            console.error('Error refreshing conversation:', error);
            this.isLoading = false;
        });
    }

    // Refresh conversation
    refreshConversation() {
        if (!this.isLoading && this.conversationData?.thread?.id && this.hasValidRecordId) {
            console.log('🔄 Refreshing conversation...');
            refreshApex(this.wiredConversation);
        }
    }

    // Start new session
    async startSession() {
        if (!this.conversationData?.thread?.id) {
            this.showToast('Error', 'No conversation thread found', 'error');
            return;
        }

        try {
            this.isLoading = true;
            console.log('🚀 Starting session for thread:', this.conversationData.thread.id);
            
            const result = await startNewSession({ threadId: this.conversationData.thread.id });
            console.log('Start session result:', result);
            
            if (result.includes('SUCCESS')) {
                this.showToast('Success', 'New session started', 'success');
                this.loadConversation();
            } else {
                this.showToast('Error', result.replace('ERROR: ', ''), 'error');
                this.isLoading = false;
            }
        } catch (error) {
            console.error('❌ Error starting session:', error);
            this.showToast('Error', this.extractErrorMessage(error), 'error');
            this.isLoading = false;
        }
    }

    // End current session
    async endSession() {
        if (!this.conversationData?.thread?.id) {
            this.showToast('Error', 'No conversation thread found', 'error');
            return;
        }

        try {
            this.isLoading = true;
            console.log('⏹️ Ending session for thread:', this.conversationData.thread.id);
            
            const result = await endSession({ threadId: this.conversationData.thread.id });
            console.log('End session result:', result);
            
            if (result.includes('SUCCESS')) {
                this.showToast('Success', 'Session ended successfully', 'success');
                this.loadConversation();
            } else {
                this.showToast('Error', result.replace('ERROR: ', ''), 'error');
                this.isLoading = false;
            }
        } catch (error) {
            console.error('❌ Error ending session:', error);
            this.showToast('Error', this.extractErrorMessage(error), 'error');
            this.isLoading = false;
        }
    }

    // Handle message input
    handleMessageInput(event) {
        this.messageText = event.target.value;
    }

    // Handle Enter key to send message
    handleKeyPress(event) {
        if (event.keyCode === 13 && !event.shiftKey) {
            event.preventDefault();
            this.sendMessage();
        }
    }

    // Send message
    async sendMessage() {
        if ((!this.messageText.trim() && !this.attachmentUrl) || !this.conversationData?.thread?.id) {
            this.showToast('Error', 'Please enter a message and ensure conversation is loaded', 'error');
            return;
        }

        this.isSending = true;
        console.log('🚀 Sending message:', this.messageText);
        console.log('🚀 Thread ID:', this.conversationData.thread.id);
        console.log('🚀 Attachment URL:', this.attachmentUrl);

        try {
            const result = await sendMessage({
                threadId: this.conversationData.thread.id,
                messageText: this.messageText,
                attachmentUrl: this.attachmentUrl
            });

            console.log('📩 Send message result:', result);

            if (result.includes('SUCCESS')) {
                this.messageText = '';
                this.clearAttachment();
                this.loadConversation();
                this.showToast('Success', 'Message sent!', 'success');
                console.log('✅ Message sent successfully');
            } else {
                console.error('❌ Send failed:', result);
                this.showToast('Error', result.replace('ERROR: ', ''), 'error');
            }
        } catch (error) {
            console.error('❌ Error sending message:', error);
            console.error('❌ Error details:', JSON.stringify(error));
            this.showToast('Error', this.extractErrorMessage(error), 'error');
        } finally {
            this.isSending = false;
        }
    }

    // File attachment handlers
    handleFileClick() {
        const fileInput = this.template.querySelector('input[type="file"]');
        if (fileInput) {
            fileInput.click();
        }
    }

    handleFileChange(event) {
        const file = event.target.files[0];
        if (file) {
            this.selectedFile = file;
            this.fileName = file.name;
            
            // Create preview for images
            if (file.type.startsWith('image/')) {
                const reader = new FileReader();
                reader.onload = (e) => {
                    this.filePreviewUrl = e.target.result;
                };
                reader.readAsDataURL(file);
            }
            
            this.attachmentUrl = `file://${file.name}`;
        }
    }

    clearAttachment() {
        this.selectedFile = null;
        this.fileName = '';
        this.filePreviewUrl = '';
        this.attachmentUrl = '';
        const fileInput = this.template.querySelector('input[type="file"]');
        if (fileInput) {
            fileInput.value = '';
        }
    }

    // Emoji handlers
    toggleEmojiPicker() {
        this.showEmojiPicker = !this.showEmojiPicker;
    }

    handleEmojiSelect(event) {
        const emoji = event.currentTarget.dataset.emoji;
        this.messageText += emoji;
        this.showEmojiPicker = false;
    }

    // Close emoji picker when clicking outside
    handleClickOutside(event) {
        const emojiPicker = this.template.querySelector('.emoji-picker');
        if (emojiPicker && !event.composedPath().includes(emojiPicker)) {
            this.showEmojiPicker = false;
        }
    }

    // Utility methods
    scrollToBottom() {
        const container = this.template.querySelector('.message-container');
        if (container) {
            container.scrollTop = container.scrollHeight;
        }
    }

    extractErrorMessage(error) {
        if (!error) return 'Unknown error occurred';
        if (typeof error === 'string') return error;
        if (error.body) {
            if (typeof error.body === 'string') return error.body;
            if (error.body.message) return error.body.message;
            if (error.body.pageErrors && error.body.pageErrors[0]) return error.body.pageErrors[0].message;
            if (error.body.fieldErrors) return JSON.stringify(error.body.fieldErrors);
        }
        return error.message || 'Unknown error occurred';
    }

    showToast(title, message, variant) {
        const toastEvent = new ShowToastEvent({
            title: title,
            message: message,
            variant: variant
        });
        this.dispatchEvent(toastEvent);
    }

    // ============ GETTERS ============

    get hasValidRecordId() {
        return this.recordId && (this.recordId.startsWith('00Q') || this.recordId.startsWith('500'));
    }

    get isWaitingForRecord() {
        return !this.recordId;
    }

    get isLead() {
        return this.recordId && this.recordId.startsWith('00Q');
    }

    get isCase() {
        return this.recordId && this.recordId.startsWith('500');
    }

    get isContact() {
        return this.recordId && this.recordId.startsWith('003');
    }

    get recordType() {
        if (this.isLead) return 'Lead';
        if (this.isCase) return 'Case';
        if (this.isContact) return 'Contact';
        return 'Record';
    }
    get displayAgentName() {
        return this.conversationData?.thread?.currentUserName || 'Agent';
    }
    get headerTitle() {
        return `Telegram Conversation - ${this.recordType}`;
    }

    get hasActiveSession() {
        return this.conversationData?.hasActiveSession === true;
    }

    get thread() {
        return this.conversationData?.thread || {};
    }

    get messages() {
        return this.conversationData?.messages || [];
    }

    get isSendDisabled() {
        return this.isSending || (!this.messageText.trim() && !this.attachmentUrl) || !this.hasActiveSession;
    }

    get hasAttachment() {
        return this.selectedFile || this.attachmentUrl;
    }

    get sendButtonClass() {
        return `send-button ${this.isSendDisabled ? 'send-button-disabled' : ''}`;
    }

    get hasConversationData() {
        return this.conversationData && !this.conversationData.error;
    }

    get hasError() {
        return this.conversationData?.error;
    }

    get errorMessage() {
        return this.conversationData?.error || 'Unknown error occurred';
    }

    get canStartSession() {
        return this.thread?.id && !this.hasActiveSession;
    }

    get canEndSession() {
        return this.thread?.id && this.hasActiveSession;
    }

    get hasNoMessages() {
        return this.processedMessages.length === 0;
    }

    // Message processing for status icons
    processMessages(messages) {
        if (!messages) return [];
        return messages.map(msg => ({
            ...msg,
            statusIcon: this.getStatusIcon(msg.status)
        }));
    }

    getStatusIcon(status) {
        switch(status) {
            case 'Sent': return 'utility:success';
            case 'Sending': return 'utility:spinner';
            case 'Failed': return 'utility:error';
            default: return 'utility:success';
        }
    }

    get processedMessages() {
        return this.processMessages(this.messages);
    }
}