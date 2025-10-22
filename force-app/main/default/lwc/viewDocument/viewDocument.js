import { LightningElement, api, track } from 'lwc';
import getAccountDocuments from '@salesforce/apex/FileController.getAccountDocuments';

export default class ViewDocument extends LightningElement {
    @api recordId;
    @track documents = [];
    @track isLoading = false;
    @track error;
    @track isZoomViewOpen = false; // Changed from isViewerOpen to isZoomViewOpen
    @track currentIndex = 0;
    @track isFullscreen = false;

    boundHandleKeyPress = null;

    connectedCallback() {
        this.loadDocuments();
        this.boundHandleKeyPress = this.handleKeyPress.bind(this);
    }

    loadDocuments() {
        this.isLoading = true;
        getAccountDocuments({ accountId: this.recordId })
        .then(result => {
            this.documents = this.addFileIcons(result || []);
            this.isLoading = false;
        })
        .catch(error => {
            this.error = error;
            this.isLoading = false;
        });
    }

    addFileIcons(documents) {
        return documents.map(doc => {
            let iconName = 'doctype:unknown';
            
            const typeToIcon = {
                'National ID': 'doctype:image',
                'ID Photograph': 'doctype:image', 
                'Proof of Address': 'doctype:pdf',
                'Income Proof': 'doctype:pdf',
                'Passport': 'doctype:pdf',
                'Driving License': 'doctype:pdf'
            };
            
            iconName = typeToIcon[doc.DocumentType] || 'doctype:unknown';
            
            return {
                ...doc,
                iconName: iconName
            };
        });
    }

    // Open zoom view when user clicks on a grid item
    openZoomView(event) {
        const index = parseInt(event.currentTarget.dataset.index);
        if (index >= 0 && index < this.documents.length) {
            this.currentIndex = index;
            this.isZoomViewOpen = true;
            this.isFullscreen = false;
            document.addEventListener('keydown', this.boundHandleKeyPress);
        }
    }

    closeZoomView() {
        this.isZoomViewOpen = false;
        document.removeEventListener('keydown', this.boundHandleKeyPress);
    }

    // Navigation methods for zoom view
    nextDocument() {
        if (this.hasNext) {
            this.currentIndex++;
        }
    }

    previousDocument() {
        if (this.hasPrevious) {
            this.currentIndex--;
        }
    }

    toggleFullscreen() {
        this.isFullscreen = !this.isFullscreen;
    }

    handleKeyPress(event) {
        if (!this.isZoomViewOpen) return;

        switch(event.key) {
            case 'ArrowLeft':
                event.preventDefault();
                this.previousDocument();
                break;
            case 'ArrowRight':
                event.preventDefault();
                this.nextDocument();
                break;
            case 'Escape':
                event.preventDefault();
                this.closeZoomView();
                break;
            case 'f':
            case 'F':
                event.preventDefault();
                this.toggleFullscreen();
                break;
        }
    }

    handleImageLoad(event) {
        console.log('Image loaded successfully');
    }

    handleImageError(event) {
        console.error('Error loading image');
    }

    // Computed properties
    get hasDocuments() {
        return Array.isArray(this.documents) && this.documents.length > 0;
    }

    get noDocuments() {
        return !this.hasDocuments;
    }

    get currentDocument() {
        return this.hasDocuments && this.documents[this.currentIndex] ? this.documents[this.currentIndex] : null;
    }

    get hasNext() {
        return this.hasDocuments && this.currentIndex < this.documents.length - 1;
    }

    get hasPrevious() {
        return this.hasDocuments && this.currentIndex > 0;
    }

    get cannotShowPrevious() {
        return !this.hasPrevious;
    }

    get cannotShowNext() {
        return !this.hasNext;
    }

    get documentCounter() {
        return this.hasDocuments ? `Document ${this.currentIndex + 1} of ${this.documents.length}` : 'No documents';
    }

    get zoomViewClass() {
        return this.isFullscreen ? 'slds-modal slds-fade-in-open zoom-view-fullscreen' : 'slds-modal slds-fade-in-open zoom-view-normal';
    }

    get fullscreenIcon() {
        return this.isFullscreen ? 'utility:minimize' : 'utility:expand_alt';
    }

    get fullscreenTitle() {
        return this.isFullscreen ? 'Exit Fullscreen' : 'Enter Fullscreen';
    }

    disconnectedCallback() {
        document.removeEventListener('keydown', this.boundHandleKeyPress);
    }
}