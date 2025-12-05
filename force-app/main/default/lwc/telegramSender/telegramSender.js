import { LightningElement, api, wire } from 'lwc';
import sendToTelegram from '@salesforce/apex/TelegramMessageSender.sendToTelegram';
import getRecordInfo from '@salesforce/apex/TelegramMessageSender.getRecordInfo';

export default class TelegramSender extends LightningElement {
    @api recordId;
    
    messageType = 'Opportunity';
    customMessage = '';
    isLoading = false;
    resultMessage = '';
    recordInfo = {};
    showCustomMessage = false;

    // Wire service to get record info
    @wire(getRecordInfo, { recordId: '$recordId' })
    wiredRecordInfo({ error, data }) {
        if (data) {
            this.recordInfo = data;
            // Set default message type based on record type
            if (data.type) {
                this.messageType = data.type;
            }
        } else if (error) {
            console.error('Error fetching record info:', error);
            this.resultMessage = '❌ Error loading record information';
        }
    }

    handleTypeChange(event) {
        this.messageType = event.target.value;
        this.showCustomMessage = this.messageType === 'Custom';
        this.resultMessage = ''; // Clear previous result
    }

    handleCustomMessageChange(event) {
        this.customMessage = event.target.value;
    }

    async handleSend() {
        // Validation
        if (this.messageType === 'Custom' && !this.customMessage.trim()) {
            this.resultMessage = '❌ Please enter a custom message';
            return;
        }

        this.isLoading = true;
        this.resultMessage = '';

        try {
            const result = await sendToTelegram({
                recordId: this.recordId,
                messageType: this.messageType,
                customMessage: this.customMessage
            });
            
            this.resultMessage = result;
            
            // Reset form on success
            if (result.includes('✅')) {
                if (this.messageType === 'Custom') {
                    this.customMessage = '';
                }
            }
            
        } catch (error) {
            console.error('Error:', error);
            this.resultMessage = '❌ Error: ' + (error.body?.message || error.message);
        } finally {
            this.isLoading = false;
        }
    }

    get typeOptions() {
        return [
            { label: 'Opportunity', value: 'Opportunity' },
            { label: 'Campaign', value: 'Campaign' },
            { label: 'Lead', value: 'Lead' },
            { label: 'Custom Message', value: 'Custom' }
        ];
    }

    get recordDisplayName() {
        return this.recordInfo.name || 'Current Record';
    }

    get isCustomType() {
        return this.messageType === 'Custom';
    }

    get isSending() {
        return this.isLoading;
    }

    get resultClass() {
        if (this.resultMessage.includes('✅')) {
            return 'success-message';
        } else if (this.resultMessage.includes('❌')) {
            return 'error-message';
        }
        return '';
    }
}