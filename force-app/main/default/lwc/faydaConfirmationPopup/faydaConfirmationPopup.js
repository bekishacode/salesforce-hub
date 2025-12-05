import { LightningElement, api } from 'lwc';
import processVerificationResult from '@salesforce/apex/FaydaVerificationHandler.processVerificationResult';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';

export default class FaydaConfirmationPopup extends LightningElement {
    @api leadId;
    @api userInfo;
    @api hasError = false;
    @api errorMessage;
    
    showSpinner = false;
    
    connectedCallback() {
        console.log('Confirmation popup opened:', {
            hasError: this.hasError,
            errorMessage: this.errorMessage,
            hasUserInfo: !!this.userInfo,
            leadId: this.leadId
        });
        
        // Show error immediately if there is one
        if (this.hasError) {
            this.showToast('Verification Failed', this.errorMessage, 'error');
        }
    }
    
    get userDetails() {
        if (!this.userInfo) return [];
        
        const details = [];
        if (this.userInfo.given_name) {
            details.push({ label: 'First Name', value: this.userInfo.given_name });
        }
        if (this.userInfo.family_name) {
            details.push({ label: 'Last Name', value: this.userInfo.family_name });
        }
        if (this.userInfo.email) {
            details.push({ label: 'Email', value: this.userInfo.email });
        }
        if (this.userInfo.phone_number) {
            details.push({ label: 'Phone', value: this.userInfo.phone_number });
        }
        if (this.userInfo.national_id) {
            details.push({ label: 'National ID', value: this.userInfo.national_id });
        }
        
        return details;
    }
    
    get showUserInfo() {
        return !this.hasError && this.userDetails.length > 0;
    }
    
    get showError() {
        return this.hasError;
    }
    
    get noDataState() {
        return !this.hasError && this.userDetails.length === 0;
    }
    
    handleFinish() {
        this.showSpinner = true;
        
        processVerificationResult({
            leadId: this.leadId,
            userInfo: this.userInfo,
            action: 'finish'
        })
        .then(result => {
            this.showToast('Success', 'Lead updated with verified information', 'success');
            this.closePopup();
        })
        .catch(error => {
            console.error('Error updating lead:', error);
            this.showToast('Error', 'Failed to update lead: ' + error.body.message, 'error');
            this.showSpinner = false;
        });
    }
    
    handleCancel() {
        this.showSpinner = true;
        
        processVerificationResult({
            leadId: this.leadId,
            userInfo: this.userInfo,
            action: 'cancel'
        })
        .then(result => {
            this.showToast('Cancelled', 'Verification was cancelled', 'info');
            this.closePopup();
        })
        .catch(error => {
            console.error('Error cancelling verification:', error);
            this.showToast('Error', 'Failed to cancel verification: ' + error.body.message, 'error');
            this.showSpinner = false;
        });
    }
    
    handleCloseError() {
        // Just close the popup when there's an error
        this.closePopup();
    }
    
    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({
            title: title,
            message: message,
            variant: variant
        }));
    }
    
    closePopup() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}